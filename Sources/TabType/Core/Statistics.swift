import Foundation

/// Local, on-device usage counters — words completed and suggestion acceptance rate,
/// plus a suggestion-lifecycle funnel (requested → generated → filtered → shown →
/// accepted) so quality regressions can be traced to the stage that eats suggestions.
/// Never leaves the Mac; purely for the user's own Statistics pane.
@MainActor
final class Statistics: ObservableObject {
    static let shared = Statistics()

    /// One countable event in a suggestion's life. Everything between `requested`
    /// and `shown` is a place a suggestion can die; the funnel makes the losses
    /// visible instead of silent.
    enum FunnelEvent: String, CaseIterable {
        case requested                    // a model generation was actually kicked off
        case gatedTypo                    // skipped: word before caret looked like a typo
        case coalescedBusy                // model busy — request deferred, retried automatically
        case superseded                   // finished, but newer input already replaced it
        case generatedEmpty               // model actually returned nothing usable
        case rejectedEcho                 // repeated what the user already typed
        case rejectedAssistantSpeak       // read like an assistant reply, not a continuation
        case rejectedSuffixOverlap        // entirely duplicated text after the caret
        case rejectedRepeatAccepted       // regenerated the just-accepted text
        case rejectedMidWordImplausible   // mid-word boundary had no plausible reading
        case discardedStale               // input changed while the model was generating
        case heldForRemainder             // prediction held while Tabbing through a suggestion
        case occupiedFallback             // inline spot had pixels — shown as HUD pill instead
        case watchdogTimeout              // generation exceeded the watchdog window
        case cacheReset                   // KV prompt cache had to be rebuilt from scratch

        var label: String {
            switch self {
            case .requested: return "Generations requested"
            case .gatedTypo: return "Skipped (typo before caret)"
            case .coalescedBusy: return "Deferred (model busy)"
            case .superseded: return "Superseded by newer input"
            case .generatedEmpty: return "Empty model output"
            case .rejectedEcho: return "Rejected (echo)"
            case .rejectedAssistantSpeak: return "Rejected (assistant-speak)"
            case .rejectedSuffixOverlap: return "Rejected (after-cursor duplicate)"
            case .rejectedRepeatAccepted: return "Rejected (repeat of accepted)"
            case .rejectedMidWordImplausible: return "Rejected (mid-word implausible)"
            case .discardedStale: return "Discarded (input changed)"
            case .heldForRemainder: return "Prediction held (Tabbing through)"
            case .occupiedFallback: return "Inline blocked → shown as pill"
            case .watchdogTimeout: return "Watchdog timeouts"
            case .cacheReset: return "KV cache rebuilds"
            }
        }
    }

    @Published private(set) var suggestionsShown: Int
    @Published private(set) var suggestionsAccepted: Int
    @Published private(set) var wordsCompleted: Int
    @Published private(set) var funnel: [FunnelEvent: Int]

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let shown = "stat_suggestionsShown"
        static let accepted = "stat_suggestionsAccepted"
        static let words = "stat_wordsCompleted"
        static func funnel(_ e: FunnelEvent) -> String { "stat_funnel_\(e.rawValue)" }
    }

    private init() {
        suggestionsShown = defaults.integer(forKey: Keys.shown)
        suggestionsAccepted = defaults.integer(forKey: Keys.accepted)
        wordsCompleted = defaults.integer(forKey: Keys.words)
        var f: [FunnelEvent: Int] = [:]
        for e in FunnelEvent.allCases {
            f[e] = defaults.integer(forKey: Keys.funnel(e))
        }
        funnel = f
    }

    var acceptanceRate: Double {
        suggestionsShown == 0 ? 0 : Double(suggestionsAccepted) / Double(suggestionsShown)
    }

    /// Fraction of kicked-off generations that survived to be shown.
    var showRate: Double {
        let requested = funnel[.requested] ?? 0
        return requested == 0 ? 0 : Double(suggestionsShown) / Double(requested)
    }

    func recordShown() {
        suggestionsShown += 1
        persist()
    }

    func recordAccepted(wordCount: Int) {
        suggestionsAccepted += 1
        wordsCompleted += wordCount
        persist()
    }

    func record(_ event: FunnelEvent) {
        funnel[event, default: 0] += 1
        defaults.set(funnel[event] ?? 0, forKey: Keys.funnel(event))
        // Periodic funnel summary so a non-verbose run still leaves evidence of
        // WHERE suggestions die.
        if event == .requested, let n = funnel[.requested], n % 50 == 0 {
            Log.shared.info("funnel: \(summaryLine())")
        }
    }

    func summaryLine() -> String {
        let parts = FunnelEvent.allCases.compactMap { e -> String? in
            let n = funnel[e] ?? 0
            return n > 0 ? "\(e.rawValue)=\(n)" : nil
        }
        return (parts + ["shown=\(suggestionsShown)", "accepted=\(suggestionsAccepted)"])
            .joined(separator: " ")
    }

    func reset() {
        suggestionsShown = 0
        suggestionsAccepted = 0
        wordsCompleted = 0
        for e in FunnelEvent.allCases {
            funnel[e] = 0
            defaults.removeObject(forKey: Keys.funnel(e))
        }
        persist()
    }

    private func persist() {
        defaults.set(suggestionsShown, forKey: Keys.shown)
        defaults.set(suggestionsAccepted, forKey: Keys.accepted)
        defaults.set(wordsCompleted, forKey: Keys.words)
    }
}
