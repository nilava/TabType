import Foundation
import Combine

/// User-configurable settings, persisted in `UserDefaults`.
/// Observable so SwiftUI views and the engine react to changes live.
@MainActor
final class AppSettings: ObservableObject {
    enum ScreenCropMode: String, CaseIterable, Codable {
        case fullWindow = "Full Window"
        case columnar = "Columnar Sorting"
        case caretCropped = "Caret-Aware Cropping (Default)"
    }

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: General
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) } }
    /// Milliseconds to wait after the last keystroke before requesting a prediction.
    /// Only used when `continuousGeneration` is off (or overridden by battery saving).
    @Published var debounceMs: Int { didSet { defaults.set(debounceMs, forKey: Keys.debounceMs) } }
    /// When true (default), fire a prediction attempt almost immediately on every
    /// keystroke rather than waiting for typing to pause — relies on `Predictor`'s
    /// coalescing to collapse a fast-typing burst to "the latest request wins,"
    /// matching Cotypist's continuous-suggestion feel. Uses more CPU while actively
    /// typing. See `batteryUseDebounce` for the automatic battery fallback.
    @Published var continuousGeneration: Bool { didSet { defaults.set(continuousGeneration, forKey: Keys.continuousGeneration) } }
    /// Max tokens to generate per suggestion (generation cap).
    @Published var maxTokens: Int { didSet { defaults.set(maxTokens, forKey: Keys.maxTokens) } }
    /// Max words shown per suggestion (display cap — the main "length" knob).
    @Published var maxWords: Int { didSet { defaults.set(maxWords, forKey: Keys.maxWords) } }
    /// Accept the whole suggestion on Tab (true) or one word at a time (false).
    @Published var acceptWholeLine: Bool { didSet { defaults.set(acceptWholeLine, forKey: Keys.acceptWholeLine) } }
    /// Ghost-text opacity, 0.15–1.0.
    @Published var ghostOpacity: Double { didSet { defaults.set(ghostOpacity, forKey: Keys.ghostOpacity) } }

    // MARK: Engine & Model
    @Published var engineChoice: EngineChoice {
        didSet { defaults.set(engineChoice.rawValue, forKey: Keys.engineChoice) }
    }
    @Published var modelId: String { didSet { defaults.set(modelId, forKey: Keys.modelId) } }

    // MARK: Shortcuts
    @Published var acceptWordKey: KeyBinding { didSet { saveBinding(acceptWordKey, Keys.acceptWordKey) } }
    @Published var acceptAllKey: KeyBinding { didSet { saveBinding(acceptAllKey, Keys.acceptAllKey) } }
    @Published var dismissKey: KeyBinding { didSet { saveBinding(dismissKey, Keys.dismissKey) } }
    @Published var toggleKey: KeyBinding { didSet { saveBinding(toggleKey, Keys.toggleKey) } }
    @Published var forceActivateKey: KeyBinding { didSet { saveBinding(forceActivateKey, Keys.forceActivateKey) } }
    @Published var appPauseKey: KeyBinding { didSet { saveBinding(appPauseKey, Keys.appPauseKey) } }
    @Published var wordAlternativesKey: KeyBinding { didSet { saveBinding(wordAlternativesKey, Keys.wordAlternativesKey) } }

    // MARK: Text tools
    @Published var emojiEnabled: Bool { didSet { defaults.set(emojiEnabled, forKey: Keys.emojiEnabled) } }
    @Published var macrosEnabled: Bool { didSet { defaults.set(macrosEnabled, forKey: Keys.macrosEnabled) } }
    @Published var autocorrectEnabled: Bool { didSet { defaults.set(autocorrectEnabled, forKey: Keys.autocorrectEnabled) } }
    @Published var skipOnTypo: Bool { didSet { defaults.set(skipOnTypo, forKey: Keys.skipOnTypo) } }
    @Published var emoticonsEnabled: Bool { didSet { defaults.set(emoticonsEnabled, forKey: Keys.emoticonsEnabled) } }
    @Published var emojiSkinTone: String { didSet { defaults.set(emojiSkinTone, forKey: Keys.emojiSkinTone) } }

    // MARK: Shortcuts behavior
    @Published var includeTrailingSpace: Bool { didSet { defaults.set(includeTrailingSpace, forKey: Keys.includeTrailingSpace) } }
    @Published var includeTrailingPunctuation: Bool { didSet { defaults.set(includeTrailingPunctuation, forKey: Keys.includeTrailingPunctuation) } }
    /// "dismiss" | "pause"
    @Published var escapeBehavior: String { didSet { defaults.set(escapeBehavior, forKey: Keys.escapeBehavior) } }

    // MARK: Battery
    @Published var batteryOnDemandOnly: Bool { didSet { defaults.set(batteryOnDemandOnly, forKey: Keys.batteryOnDemandOnly) } }
    @Published var batteryShorterCompletions: Bool { didSet { defaults.set(batteryShorterCompletions, forKey: Keys.batteryShorterCompletions) } }
    /// When true (default) and on battery in Low Power Mode, steps `continuousGeneration`
    /// down to debounced mode automatically rather than requiring a manual toggle.
    @Published var batteryUseDebounce: Bool { didSet { defaults.set(batteryUseDebounce, forKey: Keys.batteryUseDebounce) } }

    // MARK: TabType Labs (experimental)
    @Published var autocorrectLanguage: String { didSet { defaults.set(autocorrectLanguage, forKey: Keys.autocorrectLanguage) } }

    // MARK: Advanced
    @Published var temperature: Double { didSet { defaults.set(temperature, forKey: Keys.temperature) } }
    /// How many characters of preceding context to send to the model.
    @Published var contextChars: Int { didSet { defaults.set(contextChars, forKey: Keys.contextChars) } }
    /// Read the surrounding on-screen conversation (chat transcripts) as context.
    @Published var useScreenContext: Bool { didSet { defaults.set(useScreenContext, forKey: Keys.useScreenContext) } }
    /// How to crop/sort the screen context (e.g. to ignore sidebars in chat apps).
    @Published var screenCropMode: ScreenCropMode { didSet { defaults.set(screenCropMode.rawValue, forKey: Keys.screenCropMode) } }
    /// Use the clipboard contents as additional context (opt-in; may be sensitive).
    @Published var useClipboardContext: Bool { didSet { defaults.set(useClipboardContext, forKey: Keys.useClipboardContext) } }
    /// Sample the caret area to match ghost-text colour to the field (screenshot-assisted).
    @Published var useScreenshotAppearance: Bool { didSet { defaults.set(useScreenshotAppearance, forKey: Keys.useScreenshotAppearance) } }
    @Published var textMirroring: Bool { didSet { defaults.set(textMirroring, forKey: Keys.textMirroring) } }
    /// One-time hint flags.
    var didShowGoogleDocsHint: Bool {
        get { defaults.bool(forKey: Keys.didShowGoogleDocsHint) }
        set { defaults.set(newValue, forKey: Keys.didShowGoogleDocsHint) }
    }

    // MARK: General polish
    @Published var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon) } }
    @Published var showAccessoryButton: Bool { didSet { defaults.set(showAccessoryButton, forKey: Keys.showAccessoryButton) } }
    @Published var disableMacOSPredictiveText: Bool { didSet { defaults.set(disableMacOSPredictiveText, forKey: Keys.disableMacOSPredictiveText) } }
    /// "short" | "medium" | "long" → maps to maxWords.
    @Published var completionLength: String {
        didSet {
            defaults.set(completionLength, forKey: Keys.completionLength)
            maxWords = AppSettings.words(for: completionLength)
        }
    }
    static func words(for length: String) -> Int {
        switch length { case "short": return 3; case "long": return 14; default: return 8 }
    }

    // MARK: Personalization
    @Published var authorName: String { didSet { defaults.set(authorName, forKey: Keys.authorName) } }
    @Published var writingStyle: String { didSet { defaults.set(writingStyle, forKey: Keys.writingStyle) } }
    @Published var customInstructions: String { didSet { defaults.set(customInstructions, forKey: Keys.customInstructions) } }

    /// Local, encrypted typing-history collection for personalization (off by
    /// default — matches Cotypist's own default). Nothing collected here ever
    /// leaves the Mac; see `TypingHistoryStore`.
    @Published var collectTypingHistory: Bool {
        didSet { defaults.set(collectTypingHistory, forKey: Keys.collectTypingHistory) }
    }
    /// When on, every input TabType monitors is stored, not just ones where a
    /// suggestion was accepted — builds a richer dataset once collection is on.
    @Published var storeInputsWithoutAcceptedCompletions: Bool {
        didSet { defaults.set(storeInputsWithoutAcceptedCompletions, forKey: Keys.storeInputsWithoutAcceptedCompletions) }
    }
    /// 0 (off) ... 1 (max): how much stored typing history nudges word choice toward
    /// words you use often. Subtle at low values.
    @Published var personalizeWordChoice: Double {
        didSet { defaults.set(personalizeWordChoice, forKey: Keys.personalizeWordChoice) }
    }

    /// Browser domains where suggestions are disabled (bare hosts, e.g. "mail.google.com").
    @Published var disabledDomains: Set<String> { didSet { defaults.set(Array(disabledDomains), forKey: Keys.disabledDomains) } }

    /// Per-app behavior overrides, keyed by bundle id.
    @Published var appOverrides: [String: AppOverride] {
        didSet {
            AppPolicyStore.userOverrides = appOverrides
            if let data = try? JSONEncoder().encode(appOverrides) {
                defaults.set(data, forKey: Keys.appOverrides)
            }
        }
    }

    /// A short persona preface composed from personalization settings (may be empty).
    var personaPreface: String {
        var parts: [String] = []
        let name = authorName.trimmingCharacters(in: .whitespaces)
        let style = writingStyle.trimmingCharacters(in: .whitespaces)
        let notes = customInstructions.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { parts.append("The writer is \(name).") }
        if !style.isEmpty { parts.append("Writing style: \(style).") }
        if !notes.isEmpty { parts.append(notes) }
        if collectTypingHistory, personalizeWordChoice > 0 {
            // Subtle at low slider values, more pronounced near the top — a short
            // list of frequently-used words nudges the model's word choice without
            // any deep sampling/logit changes.
            let limit = max(0, Int(personalizeWordChoice * 12))
            let words = TypingHistoryStore.shared.topWords(limit: limit)
            // A 1-2 word "hint" is pure steering noise for a small model — only
            // include the sentence once there's a real signal.
            if words.count >= 3 {
                parts.append("Words this person uses often: \(words.joined(separator: ", ")).")
            }
        }
        return parts.joined(separator: " ")
    }
    /// Write verbose diagnostics to the log file.
    @Published var verboseLog: Bool {
        didSet {
            defaults.set(verboseLog, forKey: Keys.verboseLog)
            Log.shared.verbose = verboseLog
        }
    }

    // MARK: Apps (per-app enable/disable by bundle identifier)

    private init() {
        isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? true
        debounceMs = defaults.object(forKey: Keys.debounceMs) as? Int ?? 90
        continuousGeneration = defaults.object(forKey: Keys.continuousGeneration) as? Bool ?? true
        // 40 tokens: headroom for a 14-word "long" completion without mid-word
        // truncation on Qwen's tokenizer. Cheap since generation now stops at the
        // first newline / word-cap (see Predictor's didGenerate); SuggestionTrimmer
        // bounds the visible length anyway.
        var storedMaxTokens = defaults.object(forKey: Keys.maxTokens) as? Int ?? 40
        if storedMaxTokens == 28 {   // migrate the old default now that stops exist
            storedMaxTokens = 40
            defaults.set(storedMaxTokens, forKey: Keys.maxTokens)
        }
        maxTokens = storedMaxTokens
        maxWords = defaults.object(forKey: Keys.maxWords) as? Int ?? 8
        acceptWholeLine = defaults.object(forKey: Keys.acceptWholeLine) as? Bool ?? false
        ghostOpacity = defaults.object(forKey: Keys.ghostOpacity) as? Double ?? 0.45
        // Local model is the default (matches Cotypist's own architecture — it never
        // uses Apple Intelligence, confirmed by inspecting its installed binary).
        // Apple Intelligence remains available as an explicit alternate choice.
        // v2 (llama.cpp) is the default; people on the v1 local engine move over once.
        var choice = EngineChoice(rawValue: defaults.string(forKey: Keys.engineChoice) ?? "") ?? .llama
        if choice == .local, !defaults.bool(forKey: Keys.migratedToLlama) {
            choice = .llama
            defaults.set(choice.rawValue, forKey: Keys.engineChoice)
        }
        defaults.set(true, forKey: Keys.migratedToLlama)
        engineChoice = choice
        // Default to the model recommended for this Mac's hardware until the user
        // explicitly picks one.
        modelId = defaults.string(forKey: Keys.modelId) ?? HardwareInfo.recommendedModelId
        // 0 = greedy ArgMax decoding: deterministic (same prompt → same suggestion)
        // and marginally faster. MLX only uses ArgMax at exactly 0 — 0.1 still
        // SAMPLES, which fed occasional low-probability first tokens straight into
        // the rejection filters.
        var storedTemperature = defaults.object(forKey: Keys.temperature) as? Double ?? 0.0
        if storedTemperature == 0.1 {   // migrate the old default
            storedTemperature = 0.0
            defaults.set(storedTemperature, forKey: Keys.temperature)
        }
        temperature = storedTemperature
        // Must stay ≤ the PromptBuilder cap (6000) minus its reserve, or the prefix
        // gets re-truncated and context sections starve.
        contextChars = defaults.object(forKey: Keys.contextChars) as? Int ?? 1200
        // Default OFF: OCR of the focused window repeatedly bled unrelated on-screen
        // text (plans, docs, code) into suggestions. Opt-in for those who want it.
        useScreenContext = defaults.object(forKey: Keys.useScreenContext) as? Bool ?? false
        // Caret-cropped is the default: OCR only the region around the caret, which
        // keeps toolbars/sidebars/unrelated paragraphs out of the prompt.
        screenCropMode = ScreenCropMode(rawValue: defaults.string(forKey: Keys.screenCropMode) ?? "") ?? .caretCropped
        useClipboardContext = defaults.object(forKey: Keys.useClipboardContext) as? Bool ?? false
        useScreenshotAppearance = defaults.object(forKey: Keys.useScreenshotAppearance) as? Bool ?? true
        textMirroring = defaults.object(forKey: Keys.textMirroring) as? Bool ?? true
        showMenuBarIcon = defaults.object(forKey: Keys.showMenuBarIcon) as? Bool ?? true
        showAccessoryButton = defaults.object(forKey: Keys.showAccessoryButton) as? Bool ?? false
        disableMacOSPredictiveText = defaults.object(forKey: Keys.disableMacOSPredictiveText) as? Bool ?? false
        completionLength = defaults.string(forKey: Keys.completionLength) ?? "medium"
        // Prefill from the Mac's account name on first run — writing style/custom
        // instructions have no sensible universal default, so those stay blank.
        authorName = defaults.string(forKey: Keys.authorName) ?? NSFullUserName()
        writingStyle = defaults.string(forKey: Keys.writingStyle) ?? ""
        customInstructions = defaults.string(forKey: Keys.customInstructions) ?? ""
        collectTypingHistory = defaults.object(forKey: Keys.collectTypingHistory) as? Bool ?? false
        storeInputsWithoutAcceptedCompletions = defaults.object(forKey: Keys.storeInputsWithoutAcceptedCompletions) as? Bool ?? true
        personalizeWordChoice = defaults.object(forKey: Keys.personalizeWordChoice) as? Double ?? 0
        disabledDomains = Set(defaults.stringArray(forKey: Keys.disabledDomains) ?? [])
        if let data = defaults.data(forKey: Keys.appOverrides),
           let decoded = try? JSONDecoder().decode([String: AppOverride].self, from: data) {
            appOverrides = decoded
        } else {
            appOverrides = [:]
        }
        verboseLog = defaults.object(forKey: Keys.verboseLog) as? Bool ?? false
        emojiEnabled = defaults.object(forKey: Keys.emojiEnabled) as? Bool ?? true
        macrosEnabled = defaults.object(forKey: Keys.macrosEnabled) as? Bool ?? true
        autocorrectEnabled = defaults.object(forKey: Keys.autocorrectEnabled) as? Bool ?? true
        skipOnTypo = defaults.object(forKey: Keys.skipOnTypo) as? Bool ?? true
        emoticonsEnabled = defaults.object(forKey: Keys.emoticonsEnabled) as? Bool ?? true
        emojiSkinTone = defaults.string(forKey: Keys.emojiSkinTone) ?? "none"
        includeTrailingSpace = defaults.object(forKey: Keys.includeTrailingSpace) as? Bool ?? false
        includeTrailingPunctuation = defaults.object(forKey: Keys.includeTrailingPunctuation) as? Bool ?? false
        escapeBehavior = defaults.string(forKey: Keys.escapeBehavior) ?? "dismiss"
        batteryOnDemandOnly = defaults.object(forKey: Keys.batteryOnDemandOnly) as? Bool ?? false
        batteryShorterCompletions = defaults.object(forKey: Keys.batteryShorterCompletions) as? Bool ?? false
        batteryUseDebounce = defaults.object(forKey: Keys.batteryUseDebounce) as? Bool ?? true
        // Default autocorrect language to the system language if we ship it, else English.
        let sysLang = Locale.current.language.languageCode?.identifier ?? "en"
        autocorrectLanguage = defaults.string(forKey: Keys.autocorrectLanguage)
            ?? (SpellChecker.supported.contains(sysLang) ? sysLang : "en")
        acceptWordKey = AppSettings.loadBinding(Keys.acceptWordKey, default: .tab)
        acceptAllKey = AppSettings.loadBinding(Keys.acceptAllKey, default: .shiftTab)
        dismissKey = AppSettings.loadBinding(Keys.dismissKey, default: .escape)
        toggleKey = AppSettings.loadBinding(Keys.toggleKey, default: .unset)
        forceActivateKey = AppSettings.loadBinding(Keys.forceActivateKey, default: .controlBacktick)
        appPauseKey = AppSettings.loadBinding(Keys.appPauseKey, default: .controlOptionCommandP)
        wordAlternativesKey = AppSettings.loadBinding(Keys.wordAlternativesKey, default: .controlOptionSpace)

        Log.shared.verbose = verboseLog
        AppPolicyStore.userOverrides = appOverrides
    }

    private func saveBinding(_ b: KeyBinding, _ key: String) {
        if let data = try? JSONEncoder().encode(b) { defaults.set(data, forKey: key) }
    }
    private static func loadBinding(_ key: String, default def: KeyBinding) -> KeyBinding {
        guard let data = UserDefaults.standard.data(forKey: key),
              let b = try? JSONDecoder().decode(KeyBinding.self, from: data) else { return def }
        return b
    }

    /// Global enable only — per-app enablement lives in `appOverrides`/`AppPolicy`.
    func isEnabled(forBundleId bundleId: String?) -> Bool {
        isEnabled
    }

    private enum Keys {
        static let isEnabled = "isEnabled"
        static let debounceMs = "debounceMs"
        static let continuousGeneration = "continuousGeneration"
        static let maxTokens = "maxTokens"
        static let maxWords = "maxWords"
        static let acceptWholeLine = "acceptWholeLine"
        static let ghostOpacity = "ghostOpacity"
        static let engineChoice = "engineChoice"
        static let migratedToLlama = "migratedToLlamaEngine"
        static let modelId = "modelId"
        static let temperature = "temperature"
        static let contextChars = "contextChars"
        static let useScreenContext = "useScreenContext"
        static let screenCropMode = "screenCropMode"
        static let useClipboardContext = "useClipboardContext"
        static let useScreenshotAppearance = "useScreenshotAppearance"
        static let textMirroring = "textMirroring"
        static let didShowGoogleDocsHint = "didShowGoogleDocsHint"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showAccessoryButton = "showAccessoryButton"
        static let completionLength = "completionLength"
        static let disableMacOSPredictiveText = "disableMacOSPredictiveText"
        static let authorName = "authorName"
        static let writingStyle = "writingStyle"
        static let customInstructions = "customInstructions"
        static let collectTypingHistory = "collectTypingHistory"
        static let storeInputsWithoutAcceptedCompletions = "storeInputsWithoutAcceptedCompletions"
        static let personalizeWordChoice = "personalizeWordChoice"
        static let disabledDomains = "disabledDomains"
        static let appOverrides = "appOverrides"
        static let verboseLog = "verboseLog"
        static let emojiEnabled = "emojiEnabled"
        static let macrosEnabled = "macrosEnabled"
        static let autocorrectEnabled = "autocorrectEnabled"
        static let skipOnTypo = "skipOnTypo"
        static let autocorrectLanguage = "autocorrectLanguage"
        static let emoticonsEnabled = "emoticonsEnabled"
        static let emojiSkinTone = "emojiSkinTone"
        static let includeTrailingSpace = "includeTrailingSpace"
        static let includeTrailingPunctuation = "includeTrailingPunctuation"
        static let escapeBehavior = "escapeBehavior"
        static let batteryOnDemandOnly = "batteryOnDemandOnly"
        static let batteryUseDebounce = "batteryUseDebounce"
        static let batteryShorterCompletions = "batteryShorterCompletions"
        static let acceptWordKey = "acceptWordKey"
        static let acceptAllKey = "acceptAllKey"
        static let dismissKey = "dismissKey"
        static let toggleKey = "toggleKey"
        static let forceActivateKey = "forceActivateKey"
        static let appPauseKey = "appPauseKey"
        static let wordAlternativesKey = "wordAlternativesKey"
    }
}
