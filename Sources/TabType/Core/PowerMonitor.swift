import Foundation

/// Tracks Low Power Mode so the engine can back off on battery (longer debounce,
/// pause screen capture). The Apple Intelligence path is light, so this mainly
/// protects battery when the local MLX engine + OCR are active.
@MainActor
final class PowerMonitor {
    static let shared = PowerMonitor()

    private(set) var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var observer: NSObjectProtocol?

    private init() {
        // NSProcessInfoPowerStateDidChange is posted on a BACKGROUND dispatch
        // queue. A selector-based observer on this @MainActor class makes the
        // runtime's isolation check trap off-main (SIGTRAP in
        // _dispatch_assert_queue_fail — seen in a field crash report). Observe
        // with a block and hop to the main actor explicitly instead.
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { _ in
            let now = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { @MainActor in
                PowerMonitor.shared.powerStateChanged(isLowPower: now)
            }
        }
    }

    private func powerStateChanged(isLowPower now: Bool) {
        if now != isLowPower {
            isLowPower = now
            Log.shared.info("power: low-power mode \(now ? "ON" : "off")")
        }
    }

    /// Whether background screen capture should be paused.
    var shouldPauseCapture: Bool { isLowPower }
}
