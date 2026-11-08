import Foundation

/// Own only the preference change TabType made. Persist its previous value so
/// switching this feature off after a relaunch can restore the user's choice.
@MainActor
final class MacOSPredictionPreference {
    private let defaults: UserDefaults
    private let read: () -> Bool?
    private let write: (Bool?) -> Void
    private let ownershipKey = "macOSPredictionPreference.previous"

    init(defaults: UserDefaults = .standard, read: @escaping () -> Bool? = {
        CFPreferencesCopyValue("NSAutomaticInlinePredictionEnabled" as CFString,
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Bool
    }, write: @escaping (Bool?) -> Void = { value in
        CFPreferencesSetValue("NSAutomaticInlinePredictionEnabled" as CFString,
            value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse },
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }) {
        self.defaults = defaults; self.read = read; self.write = write
    }

    func apply(disabled: Bool) {
        if disabled {
            if defaults.dictionary(forKey: ownershipKey) == nil {
                let previous = read()
                defaults.set(["present": previous != nil, "value": previous ?? false], forKey: ownershipKey)
            }
            write(false)
        } else if let previous = defaults.dictionary(forKey: ownershipKey) {
            // Preserve a later change made directly in System Settings.
            if read() == false {
                write(previous["present"] as? Bool == true ? previous["value"] as? Bool : nil)
            }
            defaults.removeObject(forKey: ownershipKey)
        }
    }
}
