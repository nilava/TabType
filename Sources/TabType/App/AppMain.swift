import AppKit

@main
struct TabTypeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Agent app: no Dock icon, lives in the menu bar.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
