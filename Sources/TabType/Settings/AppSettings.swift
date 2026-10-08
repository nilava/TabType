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
    /// Max words shown per suggestion (display cap — the main "length" knob).
    @Published var maxWords: Int { didSet { defaults.set(maxWords, forKey: Keys.maxWords) } }
    /// Accept the whole suggestion on Tab (true) or one word at a time (false).
    @Published var acceptWholeLine: Bool { didSet { defaults.set(acceptWholeLine, forKey: Keys.acceptWholeLine) } }
    /// Ghost-text opacity, 0.15–1.0.
    @Published var ghostOpacity: Double { didSet { defaults.set(ghostOpacity, forKey: Keys.ghostOpacity) } }


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

    // MARK: TabType Labs (experimental)
    @Published var autocorrectLanguage: String { didSet { defaults.set(autocorrectLanguage, forKey: Keys.autocorrectLanguage) } }

    // MARK: Advanced
    /// Characters of the field before the caret that are read (the prompt
    /// assembler budgets them further).
    static let inputContextChars = 2000
    /// Read the surrounding on-screen conversation (chat transcripts) as context.
    @Published var useScreenContext: Bool { didSet { defaults.set(useScreenContext, forKey: Keys.useScreenContext) } }
    /// Use the clipboard contents as additional context (opt-in; may be sensitive).
    @Published var useClipboardContext: Bool { didSet { defaults.set(useClipboardContext, forKey: Keys.useClipboardContext) } }
    /// Sample the caret area to match ghost-text colour to the field (screenshot-assisted).
    @Published var useScreenshotAppearance: Bool { didSet { defaults.set(useScreenshotAppearance, forKey: Keys.useScreenshotAppearance) } }
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
        // Eval (seed-v1, Qwen3-4B base): past ~4 words, extra words are mostly
        // wrong ones on screen (8 → 4 words: same characters saved, fewer wrong).
        switch length { case "short": return 2; case "long": return 8; default: return 4 }
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
        // The length setting is the source of truth (older builds stored 8 here).
        maxWords = AppSettings.words(for: defaults.string(forKey: Keys.completionLength) ?? "medium")
        acceptWholeLine = defaults.object(forKey: Keys.acceptWholeLine) as? Bool ?? false
        ghostOpacity = defaults.object(forKey: Keys.ghostOpacity) as? Double ?? 0.45
        // Settings that only the removed v1 (MLX / Apple Intelligence) engine used.
        for key in Keys.retiredV1 { defaults.removeObject(forKey: key) }
        // Default OFF: OCR of the focused window repeatedly bled unrelated on-screen
        // text (plans, docs, code) into suggestions. Opt-in for those who want it.
        useScreenContext = defaults.object(forKey: Keys.useScreenContext) as? Bool ?? false
        useClipboardContext = defaults.object(forKey: Keys.useClipboardContext) as? Bool ?? false
        useScreenshotAppearance = defaults.object(forKey: Keys.useScreenshotAppearance) as? Bool ?? true
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
        static let maxWords = "maxWords"
        /// Keys of settings that only the removed v1 engine used — deleted on launch.
        static let retiredV1 = ["maxTokens", "engineChoice", "migratedToLlamaEngine", "modelId", "temperature",
                                "storeInputsWithoutAcceptedCompletions", "personalizeWordChoice",
                                // Tuning knobs removed in v2.1 (they only got in the way).
                                "debounceMs", "continuousGeneration", "contextChars", "screenCropMode",
                                "textMirroring", "batteryOnDemandOnly", "batteryUseDebounce",
                                "batteryShorterCompletions", "llamaAdapter"]
        static let acceptWholeLine = "acceptWholeLine"
        static let ghostOpacity = "ghostOpacity"
        static let useScreenContext = "useScreenContext"
        static let useClipboardContext = "useClipboardContext"
        static let useScreenshotAppearance = "useScreenshotAppearance"
        static let didShowGoogleDocsHint = "didShowGoogleDocsHint"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showAccessoryButton = "showAccessoryButton"
        static let completionLength = "completionLength"
        static let disableMacOSPredictiveText = "disableMacOSPredictiveText"
        static let authorName = "authorName"
        static let writingStyle = "writingStyle"
        static let customInstructions = "customInstructions"
        static let collectTypingHistory = "collectTypingHistory"
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
        static let acceptWordKey = "acceptWordKey"
        static let acceptAllKey = "acceptAllKey"
        static let dismissKey = "dismissKey"
        static let toggleKey = "toggleKey"
        static let forceActivateKey = "forceActivateKey"
        static let appPauseKey = "appPauseKey"
        static let wordAlternativesKey = "wordAlternativesKey"
    }
}
