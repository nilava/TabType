import AppKit

@main
struct TabTypeMain {
    static func main() {
        let arguments = CommandLine.arguments
        if EvalMode.isRequested(arguments) {
            MainActor.assumeIsolated { EvalMode.start(arguments: arguments) }
            RunLoop.main.run()   // EvalMode exits the process when done
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Agent app: no Dock icon, lives in the menu bar.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
