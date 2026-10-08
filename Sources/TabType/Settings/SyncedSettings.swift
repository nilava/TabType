import Foundation

/// The preferences that follow the author between Macs (machine-specific ones —
/// menu bar icon, accessory button, logging, enabled state — stay local).
struct SyncedSettings: Codable, Equatable {
    var ghostOpacity: Double
    var acceptWordKey, acceptAllKey, dismissKey, toggleKey, forceActivateKey, appPauseKey,
        wordAlternativesKey: KeyBinding
    var emojiEnabled, macrosEnabled, autocorrectEnabled, skipOnTypo, emoticonsEnabled: Bool
    var emojiSkinTone, emojiGender: String
    var emojiIncludeNeutral: Bool
    var includeTrailingSpace, includeTrailingPunctuation: Bool
    var escapeBehavior, autocorrectLanguage: String
    var batteryOnDemandOnly, batteryShorterCompletions, batterySmallerModel: Bool
    var useScreenContext, useClipboardContext, useScreenshotAppearance: Bool
    var completionLength, authorName, writingStyle, customInstructions: String
    var alternativesAfterDelay, synonymsAfterDelay: Bool
    var labsDelay: Double
    var personalizationStrength: String
    var recordWithoutAccepts, collectTypingHistory: Bool
    var disabledDomains: Set<String>
    var appOverrides: [String: AppOverride]
}

extension AppSettings {
    var syncSnapshot: SyncedSettings {
        SyncedSettings(
            ghostOpacity: ghostOpacity,
            acceptWordKey: acceptWordKey, acceptAllKey: acceptAllKey, dismissKey: dismissKey, toggleKey: toggleKey,
            forceActivateKey: forceActivateKey, appPauseKey: appPauseKey, wordAlternativesKey: wordAlternativesKey,
            emojiEnabled: emojiEnabled, macrosEnabled: macrosEnabled, autocorrectEnabled: autocorrectEnabled,
            skipOnTypo: skipOnTypo, emoticonsEnabled: emoticonsEnabled,
            emojiSkinTone: emojiSkinTone, emojiGender: emojiGender, emojiIncludeNeutral: emojiIncludeNeutral,
            includeTrailingSpace: includeTrailingSpace, includeTrailingPunctuation: includeTrailingPunctuation,
            escapeBehavior: escapeBehavior, autocorrectLanguage: autocorrectLanguage,
            batteryOnDemandOnly: batteryOnDemandOnly, batteryShorterCompletions: batteryShorterCompletions,
            batterySmallerModel: batterySmallerModel,
            useScreenContext: useScreenContext, useClipboardContext: useClipboardContext,
            useScreenshotAppearance: useScreenshotAppearance,
            completionLength: completionLength, authorName: authorName, writingStyle: writingStyle,
            customInstructions: customInstructions,
            alternativesAfterDelay: alternativesAfterDelay, synonymsAfterDelay: synonymsAfterDelay, labsDelay: labsDelay,
            personalizationStrength: personalizationStrength,
            recordWithoutAccepts: recordWithoutAccepts, collectTypingHistory: collectTypingHistory,
            disabledDomains: disabledDomains, appOverrides: appOverrides)
    }

    func apply(_ s: SyncedSettings) {
        ghostOpacity = s.ghostOpacity
        acceptWordKey = s.acceptWordKey; acceptAllKey = s.acceptAllKey; dismissKey = s.dismissKey
        toggleKey = s.toggleKey; forceActivateKey = s.forceActivateKey; appPauseKey = s.appPauseKey
        wordAlternativesKey = s.wordAlternativesKey
        emojiEnabled = s.emojiEnabled; macrosEnabled = s.macrosEnabled; autocorrectEnabled = s.autocorrectEnabled
        skipOnTypo = s.skipOnTypo; emoticonsEnabled = s.emoticonsEnabled
        emojiSkinTone = s.emojiSkinTone; emojiGender = s.emojiGender; emojiIncludeNeutral = s.emojiIncludeNeutral
        includeTrailingSpace = s.includeTrailingSpace; includeTrailingPunctuation = s.includeTrailingPunctuation
        escapeBehavior = s.escapeBehavior; autocorrectLanguage = s.autocorrectLanguage
        batteryOnDemandOnly = s.batteryOnDemandOnly; batteryShorterCompletions = s.batteryShorterCompletions
        batterySmallerModel = s.batterySmallerModel
        useScreenContext = s.useScreenContext; useClipboardContext = s.useClipboardContext
        useScreenshotAppearance = s.useScreenshotAppearance
        completionLength = s.completionLength; authorName = s.authorName; writingStyle = s.writingStyle
        customInstructions = s.customInstructions
        alternativesAfterDelay = s.alternativesAfterDelay; synonymsAfterDelay = s.synonymsAfterDelay
        labsDelay = s.labsDelay
        personalizationStrength = s.personalizationStrength
        recordWithoutAccepts = s.recordWithoutAccepts; collectTypingHistory = s.collectTypingHistory
        disabledDomains = s.disabledDomains; appOverrides = s.appOverrides
    }
}
