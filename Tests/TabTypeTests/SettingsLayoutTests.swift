import AppKit
import SwiftUI
import XCTest
@testable import TabType

@MainActor
final class SettingsLayoutTests: XCTestCase {
    /// Exercise the real hosted Settings tree without ordering a test window on screen.
    func testSearchStaysInsideContentAtMinimumAndNormalSizes() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousPane = defaults.object(forKey: "settings.lastPane")
        defer { defaults.set(previousPane, forKey: "settings.lastPane") }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for size in [SettingsWindow.minimumContentSize, NSSize(width: 860, height: 620)] {
                SettingsNavigator.shared.pendingSection = .general
                let view = SettingsView().environmentObject(AppSettings.shared)
                    .environmentObject(LlamaModelManager.shared)
                let window = SettingsWindow.make(rootView: view)
                defer { window.close() }
                window.appearance = NSAppearance(named: appearance)
                window.setContentSize(size)
                for _ in 0..<5 {
                    window.contentView?.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                }
                let content = window.contentLayoutRect
                let root = try XCTUnwrap(window.contentView)
                let field = try XCTUnwrap(findSearch(in: root), "Native settings search field")
                let frame = field.convert(field.bounds, to: nil)
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                XCTAssertTrue(content.insetBy(dx: -1, dy: -1).contains(frame),
                    "Search \(frame) exceeds \(content) at \(size) / \(appearance)")
            }
        }
    }

    private func findSearch(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == "Find a setting" { return field }
        for child in view.subviews {
            if let field = findSearch(in: child) { return field }
        }
        return nil
    }
}
