import CoreGraphics
import Foundation

/// Lets the menu bar (or other UI outside the Settings window) jump straight to a
/// specific settings section when Settings opens and update the native window title.
@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()
    @Published var title = "Setup"
    @Published var pendingSection: SettingsView.Section?
    private init() {}
}
