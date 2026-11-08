import AppKit
import SwiftUI

/// Keep the hosting view inside AppKit's unobscured content area.
@MainActor
enum SettingsWindow {
    static let minimumContentSize = NSSize(width: 780, height: 540)

    static func make<Content: View>(rootView: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(hosting)
        let guide = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: guide.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
        window.contentMinSize = minimumContentSize
        window.isReleasedWhenClosed = false
        window.title = "TabType Settings"
        window.center()
        return window
    }
}
