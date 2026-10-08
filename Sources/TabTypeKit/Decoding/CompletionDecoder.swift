import Accelerate
import Foundation

public struct DecoderOptions: Sendable, Equatable {
    /// First-step fan-out: how many distinct first tokens are explored in parallel.
    public var candidates = 4
    /// First tokens below this probability are not explored.
    public var minFirstTokenProbability = 0.02
    /// After the beam picks a phrase, words past the first are kept while each
    /// one's probability (given the words before it) stays at or above this; 0
    /// shows the whole phrase, >1 disables extension.
    /// Eval seed-v1 (Qwen3-4B base, 4 words): 0.2 keeps ~95% of the accepted
    /// characters of no bar at all (3.62 vs 3.81 per case) with ~40% fewer wrong
    /// trailing words; 0.5 made almost every suggestion a single word.
    public var extensionThreshold = 0.2
    /// Hard cap on suggested words (including the first).
    public var maxWords = 4
    /// Phrases kept alive while searching past the first word (Cotypist: 9). The
    /// winner is the phrase with the highest total probability.
    public var beamWidth = 9
    /// Next tokens considered per phrase at each step.
    public var beamBranching = 3
    /// Search only phrases that start with the most likely first word (keeps the
    /// first word — the one the show gate judges — the model's best guess).
    public var beamFromBestFirstWord = true
    /// Recommended minimum first-word confidence for showing a suggestion. The
    /// decoder itself never gates — callers compare `CompletionResult.confidence`
    /// against this (tuned on eval seed-v1; see `tabtype-eval sweep`).
    public var showThreshold = 0.2
    /// Token cap per word (guards against runaway tokens such as long numbers).
    public var maxTokensPerWord = 8
    /// How many runner-up first words to report in `alternatives`.
    public var maxAlternatives = 3
    /// What the author wrote after these words before (from their own writing).
    /// Explored as an extra candidate scored with true model probabilities, and
    /// preferred by `hintBonus` (log-space) when choosing the winner.
    public var hint: [UInt8] = []
    public var hintBonus = log(3.0)

    public init() {}
}

/// One word of a suggestion with the model's probability for it (conditional on
/// everything before it).
public struct WordScore: Sendable, Equatable {
    public var text: String
    public var probability: Double
}

public struct CompletionResult: Sendable, Equatable {
    /// Text to show/insert at the caret.
    public var text: String
    /// Probability of the first word given what was typed — the confidence gate.
    public var confidence: Double
    public var words: [WordScore]
    /// Other first words the model considered, best first.
    public var alternatives: [WordScore]
    /// The model expects a space after the last suggested word.
    public var predictedTrailingSpace: Bool
    public var promptTokens: Int
    public var generatedTokens: Int
    /// The winner agrees with the author's past writing (`DecoderOptions.hint`).
    public var followsHint: Bool = false
}

/// Confidence-scored completion on raw logits: token healing, parallel first-word
/// candidates, duplicate merging, and probability-gated phrase extension.
public enum CompletionDecoder {
    /// Words that fit at the end of `text` (e.g. in place of a selected word),
    /// most likely first, excluding `excluded` — the word picker's "synonyms".
    /// Trailing punctuation is dropped unless `excluded` itself ends with some.
    public static func wordsThatFit(after text: String, excluding excluded: String, model: TokenModel,
                                    count: Int = 4, isCancelled: @escaping () -> Bool = { false }) throws -> [WordScore] {
        var options = DecoderOptions()
        options.candidates = max(1, model.maxSequences - 1)
        options.minFirstTokenProbability = 0.005
        options.extensionThreshold = 2   // single words
        options.maxAlternatives = options.candidates
        guard let result = try complete(text, model: model, options: options, isCancelled: isCancelled) else { return [] }
        let keepPunctuation = excluded.last.map { $0.isPunctuation } ?? false
        let normalized = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() }
        let skip = normalized(excluded)
        var seen = Set<String>()
        return (result.words.prefix(1) + result.alternatives)
            .map { w -> WordScore in
                var t = w.text.trimmingCharacters(in: .whitespaces)
                if !keepPunctuation { while let last = t.last, last.isPunctuation { t.removeLast() } }
                return WordScore(text: t, probability: w.probability)
            }
            .filter { w in
                let n = normalized(w.text)
                return !n.isEmpty && n != skip && seen.insert(n).inserted
            }
            .prefix(count).map { $0 }
    }

    /// Replacements for a selected word: candidates from the left context and from
    /// asking the model directly, ranked by P(word + following text | text before) —
    /// so "the ___ turnaround" prefers "fast" over words that only fit the left side.
    public static func replacements(before: String, selected: String, after: String, model: TokenModel,
                                    count: Int = 4, isCancelled: @escaping () -> Bool = { false }) throws -> [WordScore] {
        // Two candidate pools: words that fit the left context, and words the model
        // offers when asked directly what the selected word could also be.
        let sentenceStart = before.lastIndex(where: { ".!?\n".contains($0) }).map { before.index(after: $0) }
        let leftSentence = String(before[(sentenceStart ?? before.startIndex)...].suffix(160))
            .trimmingCharacters(in: .whitespaces)
        let rightSentence = after.prefix { !".!?\n".contains($0) }
        let question = "\(leftSentence)\(selected)\(rightSentence).\nIn this sentence, \"\(selected)\" could also be \""
        var candidates = try wordsThatFit(after: question, excluding: selected, model: model, count: 7,
                                          isCancelled: isCancelled)
        for word in try wordsThatFit(after: before, excluding: selected, model: model, count: 7, isCancelled: isCancelled)
        where !candidates.contains(where: { $0.text.lowercased() == word.text.lowercased() }) {
            candidates.append(word)
        }
        // A few words of what follows are enough to judge the fit.
        let snippet = String(after.prefix(40)).split(separator: " ", omittingEmptySubsequences: false)
            .prefix(4).joined(separator: " ")
        guard !snippet.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(candidates.prefix(count)) }
        let separator = before.last?.isWhitespace == false && !before.isEmpty ? " " : ""
        var scored: [(WordScore, Double)] = []
        for c in candidates {
            if isCancelled() { throw CancellationError() }
            // Joint P(word + following text | text before), in ONE context for every
            // candidate — the pools' own probabilities came from different prompts.
            let fit = try continuationLogProbability(prefix: before, continuation: separator + c.text + snippet,
                                                     model: model)
            scored.append((c, fit))
        }
        // Drop options far less likely than the best (>6 nats ≈ 400× less likely):
        // a short list of good replacements beats padding it with junk.
        let ranked = scored.sorted { $0.1 > $1.1 }
        guard let best = ranked.first?.1 else { return [] }
        return ranked.filter { $0.1 >= best - 6 }.prefix(count).map(\.0)
    }

    /// log P(continuation | prefix), from one prompt evaluation plus one batched
    /// decode on a scratch sequence.
    public static func continuationLogProbability(prefix: String, continuation: String,
                                                  model: TokenModel) throws -> Double {
        let full = model.tokenize(prefix + continuation, addSpecial: true)
        let head = model.tokenize(prefix, addSpecial: true)
        var k = 0
        while k < min(full.count, head.count), full[k] == head[k] { k += 1 }
        k = min(k, full.count - 1)
        guard k >= 1 else { return 0 }
        var scratch: [Float] = []
        func logProb(_ logits: Logits, _ token: TokenID) -> Double {
            Double(logits.values[Int(token)] - LogitMath.logSumExp(logits, blocked: nil, scratch: &scratch))
        }
        var total = logProb(try model.evaluatePrompt(Array(full[..<k])), full[k])
        if full.count - k > 1 {
            model.fork(to: 1)
            defer { model.drop(sequence: 1) }
            let entries = (k..<(full.count - 1)).map { BatchEntry(token: full[$0], position: $0, sequence: 1) }
            for (i, logits) in try model.decode(entries).enumerated() {
                total += logProb(logits, full[k + i + 1])
            }
        }
        return total
    }

    /// - Parameter text: everything before the caret, as it should be continued
    ///   (context included). The typed text must be at its very end.
    /// - Parameter isCancelled: polled between decode steps; a true result aborts.
    public static func complete(_ text: String, model: TokenModel, options: DecoderOptions = DecoderOptions(),
                                isCancelled: @escaping () -> Bool = { false }) throws -> CompletionResult? {
        var split = HealSplit.split(text)
        var promptTokens = model.tokenize(split.prompt, addSpecial: true)
        // Heal bytes no single token can start (exotic scripts/byte runs): fall back
        // to continuing the raw text unhealed.
        if !split.heal.isEmpty, model.vocab.tokens(consistentWith: split.heal[...]).isEmpty {
            split = HealSplit(prompt: text, heal: [])
            promptTokens = model.tokenize(text, addSpecial: true)
        }
        guard !promptTokens.isEmpty else { return nil }

        var session = Session(model: model, options: options, heal: split.heal,
                              promptLength: promptTokens.count, isCancelled: isCancelled)
        defer { session.dropSequences() }
        let logits = try model.evaluatePrompt(promptTokens)
        return try session.run(promptLogits: logits)
    }
}

// MARK: - Search

private struct Candidate {
    var sequence: Int
    var tokens: [TokenID] = []
    /// All generated bytes, heal included.
    var bytes: [UInt8] = []
    var pendingHeal: ArraySlice<UInt8>
    /// Hint bytes this candidate still follows (only the hint candidate has any).
    var forced: ArraySlice<UInt8> = []
    var logProbability: Double = 0
    var finished = false
    /// The token chosen but not fed when the word ended — the next word's start.
    var stopToken: TokenID?
    var stopLogProbability: Double = 0
    var logits: Logits?
    /// Next-word starts the beam may take, read when the word ended.
    var nextChoices: [Choice] = []
}

private struct Choice { var token: TokenID; var logProbability: Double }

/// One phrase in the beam past the first word.
private struct Phrase {
    var sequence: Int
    /// Position of the next token to feed.
    var position: Int
    var logProbability: Double
    /// Finished words, the first included, as visible bytes.
    var words: [[UInt8]]
    var wordLogProbabilities: [Double]
    var current: [UInt8] = []
    var currentLogProbability: Double = 0
    var tokensInWord = 0
    var proposals: [Choice]
    var forced: ArraySlice<UInt8>
    var followsHint: Bool
    /// Index of its first word in the merged first-word list.
    var root: Int
    var trailingSpace = false
}

private struct Session {
    let model: TokenModel
    let options: DecoderOptions
    let heal: [UInt8]
    let promptLength: Int
    let isCancelled: () -> Bool
    var usedSequences: [Int] = []
    var scratch: [Float] = []
    var generated = 0

    init(model: TokenModel, options: DecoderOptions, heal: [UInt8], promptLength: Int,
         isCancelled: @escaping () -> Bool) {
        self.model = model
        self.options = options
        self.heal = heal
        self.promptLength = promptLength
        self.isCancelled = isCancelled
    }

    var vocab: VocabIndex { model.vocab }

    mutating func dropSequences() {
        for seq in usedSequences { model.drop(sequence: seq) }
        usedSequences.removeAll()
    }

    // MARK: Stage A — first word, candidates in parallel

    mutating func run(promptLogits: Logits) throws -> CompletionResult? {
        let healSlice = heal[...]
        let allowed = heal.isEmpty ? nil : vocab.tokens(consistentWith: healSlice)
        let norm = normalizer(promptLogits, allowed: allowed)
        let fanOut = min(options.candidates, model.maxSequences - 1)
        // Suggestions continue the current line; never open with a line break.
        var firsts = LogitMath.topK(promptLogits, k: fanOut, candidates: allowed, blocked: vocab.blocked)
            .filter { !vocab.containsNewline($0) }
            .filter { exp(Double(promptLogits.values[Int($0)] - norm)) >= options.minFirstTokenProbability }
        if firsts.isEmpty, let best = LogitMath.topK(promptLogits, k: 1, candidates: allowed, blocked: vocab.blocked).first {
            firsts = [best]
        }
        // The author's own continuation joins the candidates (if the model gives it
        // any chance at all), replacing the weakest when the fan-out is full.
        var hintToken: TokenID?
        if !options.hint.isEmpty {
            let required = (heal + options.hint)[...]
            let consistent = vocab.tokens(consistentWith: required).filter { !vocab.containsNewline($0) }
            if let token = LogitMath.topK(promptLogits, k: 1, candidates: consistent, blocked: vocab.blocked).first {
                hintToken = token
                if !firsts.contains(token) {
                    if firsts.count >= fanOut, !firsts.isEmpty { firsts.removeLast() }
                    firsts.append(token)
                }
            }
        }
        guard !firsts.isEmpty else { return nil }

        var candidates: [Candidate] = []
        var entries: [BatchEntry] = []
        for (i, token) in firsts.enumerated() {
            let seq = i + 1
            model.fork(to: seq)
            usedSequences.append(seq)
            var c = Candidate(sequence: seq, pendingHeal: healSlice)
            if token == hintToken { c.forced = options.hint[...] }
            // The first token's probability is conditional on reproducing the typed
            // partial word (renormalized over consistent tokens) — or, with nothing
            // to heal, its plain probability.
            let lp = Double(promptLogits.values[Int(token)] - norm)
            // A first token can itself end the word immediately (heal fully
            // consumed and the token already holds a complete word + boundary is
            // decided on the NEXT token), so it is always fed.
            append(token, logProbability: lp, to: &c)
            candidates.append(c)
            entries.append(BatchEntry(token: token, position: promptLength, sequence: seq))
        }
        try feed(entries, into: &candidates, indices: Array(candidates.indices))

        while candidates.contains(where: { !$0.finished }) {
            if isCancelled() { throw CancellationError() }
            var batch: [BatchEntry] = []
            var batchOwners: [Int] = []
            for i in candidates.indices where !candidates[i].finished {
                guard let next = choose(for: candidates[i]) else {
                    candidates[i].finished = true
                    continue
                }
                if shouldEndWord(candidates[i], before: next.token) {
                    candidates[i].finished = true
                    candidates[i].nextChoices = wordStarts(candidates[i].logits!, forced: candidates[i].forced)
                    // Only a whitespace-led token starts a next word worth extending into.
                    let startsWord = vocab.startsWithWhitespace(next.token) && !vocab.containsNewline(next.token)
                    candidates[i].stopToken = startsWord ? next.token : nil
                    candidates[i].stopLogProbability = next.logProbability
                    continue
                }
                append(next.token, logProbability: next.logProbability, to: &candidates[i])
                batch.append(BatchEntry(token: next.token,
                                        position: promptLength + candidates[i].tokens.count - 1,
                                        sequence: candidates[i].sequence))
                batchOwners.append(i)
            }
            try feed(batch, into: &candidates, indices: batchOwners)
        }

        // Merge candidates that render the same visible text (different
        // tokenizations of one word), summing their probability mass.
        var merged: [(text: String, logP: Double, index: Int, followsHint: Bool)] = []
        for (i, c) in candidates.enumerated() {
            let text = visibleText(c)
            guard text.contains(where: { !$0.isWhitespace }) else { continue }
            let visible = Array(visibleBytes(c))
            let agrees = !options.hint.isEmpty
                && (options.hint.starts(with: visible) || visible.starts(with: options.hint))
            if let j = merged.firstIndex(where: { $0.text == text }) {
                merged[j].logP = logAddExp(merged[j].logP, c.logProbability)
                merged[j].followsHint = merged[j].followsHint || agrees
            } else {
                merged.append((text, c.logProbability, i, agrees))
            }
        }
        // Rank with the hint bonus; report the model's true probability.
        let bonus = options.hintBonus
        merged.sort { ($0.logP + ($0.followsHint ? bonus : 0)) > ($1.logP + ($1.followsHint ? bonus : 0)) }
        guard let best = merged.first else { return nil }

        // Past the first word: beam search over whole phrases (Cotypist's search),
        // starting from every first word, ranked by total probability.
        var root = 0
        var words = [WordScore(text: best.text, probability: exp(best.logP))]
        var trailingSpace = candidates[best.index].stopToken.map { vocab.pieces[Int($0)].first == 0x20 } ?? false
        if options.maxWords > 1, options.extensionThreshold <= 1,
           let phrase = try beam(from: candidates, merged: merged) {
            root = phrase.root
            let first = merged[root]
            words = [WordScore(text: first.text, probability: exp(first.logP))]
            for (bytes, lp) in zip(phrase.words.dropFirst(), phrase.wordLogProbabilities.dropFirst()) {
                // Trailing words stay only while each is likely enough given the
                // ones before it.
                guard exp(lp) >= options.extensionThreshold else { break }
                words.append(WordScore(text: String(decoding: bytes, as: UTF8.self), probability: exp(lp)))
            }
            trailingSpace = phrase.trailingSpace
        }
        let chosen = merged[root]

        return CompletionResult(
            text: words.map(\.text).joined(),
            confidence: exp(chosen.logP),
            words: words,
            alternatives: merged.enumerated().filter { $0.offset != root }.prefix(options.maxAlternatives)
                .map { WordScore(text: $0.element.text, probability: exp($0.element.logP)) },
            predictedTrailingSpace: trailingSpace,
            promptTokens: promptLength,
            generatedTokens: generated,
            followsHint: chosen.followsHint)
    }

    // MARK: Stage B — beam search over phrases

    /// What may follow a phrase whose word just ended: the best few space-led
    /// word starts or line breaks (a line break ends the phrase), plus the
    /// author's own next token when following a hint.
    mutating func wordStarts(_ logits: Logits, forced: ArraySlice<UInt8>) -> [Choice] {
        let norm = LogitMath.logSumExp(logits, blocked: nil, scratch: &scratch)
        var choices = LogitMath.topK(logits, k: options.beamBranching * 2, candidates: nil, blocked: vocab.blocked)
            .filter { vocab.startsWithWhitespace($0) || vocab.containsNewline($0) }
            .prefix(options.beamBranching)
            .map { Choice(token: $0, logProbability: Double(logits.values[Int($0)] - norm)) }
        if !forced.isEmpty, let f = forcedChoice(forced, logits), !choices.contains(where: { $0.token == f.token }) {
            choices.append(f)
        }
        return choices
    }

    /// The most probable phrase of up to `maxWords` words, or nil when no first
    /// word can be extended. Phrases share KV state until they branch.
    mutating func beam(from candidates: [Candidate],
                       merged: [(text: String, logP: Double, index: Int, followsHint: Bool)]) throws -> Phrase? {
        var live: [Phrase] = []
        var done: [Phrase] = []
        var keep = Set<Int>()
        for (r, m) in merged.enumerated() {
            let c = candidates[m.index]
            if options.beamFromBestFirstWord, r > 0 { continue }
            keep.insert(c.sequence)
            let phrase = Phrase(sequence: c.sequence, position: promptLength + c.tokens.count,
                                logProbability: c.logProbability, words: [Array(visibleBytes(c))],
                                wordLogProbabilities: [c.logProbability], proposals: c.nextChoices,
                                forced: c.forced, followsHint: m.followsHint, root: r)
            // A first word that ended the text (line break, end of generation) is
            // the whole phrase.
            if phrase.proposals.isEmpty || c.stopToken == nil { done.append(phrase) } else { live.append(phrase) }
        }
        // Candidates that merged into another's text are done with their KV.
        for c in candidates where !keep.contains(c.sequence) { model.drop(sequence: c.sequence) }

        var steps = 0
        while !live.isEmpty, steps < options.maxWords * options.maxTokensPerWord {
            steps += 1
            if isCancelled() { throw CancellationError() }
            // Every phrase × its next-token options, best total probability first.
            var expansions: [(parent: Int, choice: Choice, score: Double)] = []
            for (i, p) in live.enumerated() {
                for choice in p.proposals {
                    let startsWord = vocab.startsWithWhitespace(choice.token)
                    if vocab.containsNewline(choice.token)
                        || (startsWord && !p.current.isEmpty && p.words.count + 1 >= options.maxWords)
                        || (!startsWord && p.tokensInWord >= options.maxTokensPerWord) {
                        // Ends here: a line break, the word cap, or a runaway word.
                        var finished = p
                        finished.logProbability += choice.logProbability
                        finished.trailingSpace = startsWord
                        commitWord(&finished)
                        done.append(finished)
                        continue
                    }
                    expansions.append((i, choice, p.logProbability + choice.logProbability))
                }
            }
            // A phrase's probability only falls as it grows, so nothing scoring
            // below the best finished phrase can still win — drop it (exact).
            let bonus = options.hintBonus
            let bestDone = done.map { $0.logProbability + ($0.followsHint ? bonus : 0) }.max() ?? -.infinity
            expansions.removeAll { $0.score + (live[$0.parent].followsHint ? bonus : 0) <= bestDone }
            expansions.sort { $0.score > $1.score }
            let kept = Array(expansions.prefix(options.beamWidth))
            // Phrases nothing grows from release their KV (unless finished above,
            // which no longer need it either).
            let parents = Set(kept.map(\.parent))
            for (i, p) in live.enumerated() where !parents.contains(i) { model.drop(sequence: p.sequence) }

            // Children: the first reuses its parent's sequence; the rest branch
            // into free sequences copied from the parent BEFORE anything is fed.
            var used = Set(kept.map { live[$0.parent].sequence })
            var claimed = Set<Int>()
            var next: [Phrase] = []
            var entries: [BatchEntry] = []
            for e in kept {
                var child = live[e.parent]
                if claimed.contains(child.sequence) {
                    guard let free = (1..<model.maxSequences).first(where: { !used.contains($0) }) else { continue }
                    model.copy(sequence: child.sequence, to: free)
                    used.insert(free)
                    if !usedSequences.contains(free) { usedSequences.append(free) }
                    child.sequence = free
                }
                claimed.insert(child.sequence)
                if vocab.startsWithWhitespace(e.choice.token) { commitWord(&child) }
                let piece = vocab.pieces[Int(e.choice.token)]
                child.current += piece
                child.currentLogProbability += e.choice.logProbability
                child.logProbability += e.choice.logProbability
                child.tokensInWord += 1
                if !child.forced.isEmpty {
                    child.forced = child.forced.starts(with: piece) ? child.forced.dropFirst(piece.count) : [][...]
                }
                entries.append(BatchEntry(token: e.choice.token, position: child.position, sequence: child.sequence))
                child.position += 1
                next.append(child)
            }
            let logits = try model.decode(entries)
            generated += entries.count
            for i in next.indices {
                let l = logits[i]
                let norm = LogitMath.logSumExp(l, blocked: nil, scratch: &scratch)
                // The model wants to stop: the phrase ends with this word.
                var best: Float = 0
                var bestIndex: vDSP_Length = 0
                vDSP_maxvi(l.values.baseAddress!, 1, &best, &bestIndex, vDSP_Length(l.values.count))
                if vocab.blocked[Int(bestIndex)] {
                    var finished = next[i]
                    finished.logProbability += Double(best - norm)
                    commitWord(&finished)
                    done.append(finished)
                    next[i].proposals = []
                    continue
                }
                var choices = LogitMath.topK(l, k: options.beamBranching, candidates: nil, blocked: vocab.blocked)
                    .map { Choice(token: $0, logProbability: Double(l.values[Int($0)] - norm)) }
                if !next[i].forced.isEmpty, let f = forcedChoice(next[i].forced, l),
                   !choices.contains(where: { $0.token == f.token }) {
                    choices.append(f)
                }
                next[i].proposals = choices
            }
            live = next.filter { !$0.proposals.isEmpty }
        }
        // Out of steps: what's live is as long as it gets.
        for var p in live { commitWord(&p); done.append(p) }
        for p in live { model.drop(sequence: p.sequence) }
        let bonus = options.hintBonus
        return done.max { ($0.logProbability + ($0.followsHint ? bonus : 0))
            < ($1.logProbability + ($1.followsHint ? bonus : 0)) }
    }

    /// Close the word in progress.
    func commitWord(_ p: inout Phrase) {
        guard !p.current.isEmpty else { return }
        p.words.append(p.current)
        p.wordLogProbabilities.append(p.currentLogProbability)
        p.current = []
        p.currentLogProbability = 0
        p.tokensInWord = 0
    }

    // MARK: Steps

    /// The next token for a candidate: constrained to the remaining heal while it
    /// lasts, greedy afterwards. nil when the model wants to end here.
    mutating func choose(for c: Candidate) -> Choice? {
        guard let logits = c.logits else { return nil }
        if !c.pendingHeal.isEmpty {
            let allowed = vocab.tokens(consistentWith: c.pendingHeal)
            guard let token = LogitMath.topK(logits, k: 1, candidates: allowed, blocked: vocab.blocked).first else {
                return nil
            }
            let norm = LogitMath.logSumExp(logits, over: allowed)
            return Choice(token: token, logProbability: Double(logits.values[Int(token)] - norm))
        }
        if !c.forced.isEmpty, let choice = forcedChoice(c.forced, logits) { return choice }
        return greedy(logits)
    }

    /// Follow the author's past phrasing, scored with TRUE probabilities so the
    /// confidence stays honest.
    mutating func forcedChoice(_ forced: ArraySlice<UInt8>, _ logits: Logits) -> Choice? {
        let allowed = vocab.tokens(consistentWith: forced)
        guard let token = LogitMath.topK(logits, k: 1, candidates: allowed, blocked: vocab.blocked).first else {
            return nil
        }
        let norm = LogitMath.logSumExp(logits, blocked: nil, scratch: &scratch)
        return Choice(token: token, logProbability: Double(logits.values[Int(token)] - norm))
    }

    /// Unconstrained greedy step over the whole vocabulary. nil when the best token
    /// is a control/end-of-generation token.
    mutating func greedy(_ logits: Logits) -> Choice? {
        var maxValue: Float = 0
        var maxIndex: vDSP_Length = 0
        vDSP_maxvi(logits.values.baseAddress!, 1, &maxValue, &maxIndex, vDSP_Length(logits.values.count))
        let token = TokenID(maxIndex)
        guard !vocab.blocked[Int(token)] else { return nil }
        let norm = LogitMath.logSumExp(logits, blocked: nil, scratch: &scratch)
        return Choice(token: token, logProbability: Double(maxValue - norm))
    }

    func shouldEndWord(_ c: Candidate, before token: TokenID) -> Bool {
        guard c.pendingHeal.isEmpty else { return false }
        if vocab.endOfGeneration[Int(token)] { return true }
        let visible = visibleBytes(c)
        let hasContent = visible.contains { $0 != 0x20 && $0 != 0x0A && $0 != 0x09 }
        if vocab.containsNewline(token) { return true }
        if hasContent, vocab.startsWithWhitespace(token) { return true }
        return c.tokens.count >= options.maxTokensPerWord + 2
    }

    mutating func append(_ token: TokenID, logProbability: Double, to c: inout Candidate) {
        let piece = vocab.pieces[Int(token)]
        c.tokens.append(token)
        c.bytes += piece
        c.logProbability += logProbability
        let healed = min(c.pendingHeal.count, piece.count)
        if !c.pendingHeal.isEmpty {
            c.pendingHeal = piece.count >= c.pendingHeal.count ? [][...] : c.pendingHeal.dropFirst(piece.count)
        }
        let beyondHeal = piece[healed...]
        if !c.forced.isEmpty, !beyondHeal.isEmpty {
            c.forced = c.forced.starts(with: beyondHeal) ? c.forced.dropFirst(beyondHeal.count) : [][...]
        }
        generated += 1
    }

    mutating func feed(_ entries: [BatchEntry], into candidates: inout [Candidate], indices: [Int]) throws {
        guard !entries.isEmpty else { return }
        let logits = try model.decode(entries)
        for (k, i) in indices.enumerated() { candidates[i].logits = logits[k] }
    }

    mutating func normalizer(_ logits: Logits, allowed: [TokenID]?) -> Float {
        if let allowed { return LogitMath.logSumExp(logits, over: allowed) }
        return LogitMath.logSumExp(logits, blocked: nil, scratch: &scratch)
    }

    func visibleBytes(_ c: Candidate) -> ArraySlice<UInt8> {
        c.bytes.count > heal.count ? c.bytes[heal.count...] : []
    }

    func visibleText(_ c: Candidate) -> String {
        String(decoding: visibleBytes(c), as: UTF8.self)
    }
}

private func logAddExp(_ a: Double, _ b: Double) -> Double {
    let m = max(a, b)
    return m + log(exp(a - m) + exp(b - m))
}
