import Foundation
import IOKit.ps

/// Tracks Low Power Mode (pause screen capture) and whether the Mac runs on
/// battery (the "On battery power" settings: on-demand only, shorter
/// suggestions, a smaller model).
@MainActor
final class PowerMonitor {
    static let shared = PowerMonitor()

    private(set) var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Running on battery rather than mains power.
    private(set) var onBattery = PowerMonitor.readOnBattery()
    /// Called on the main thread when `onBattery` changes.
    var onBatteryChange: ((Bool) -> Void)?

    private var observer: NSObjectProtocol?
    private var powerSource: CFRunLoopSource?

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
        // Battery ⇄ mains: IOKit's power-source notification on the main run loop.
        let callback: IOPowerSourceCallbackType = { _ in
            MainActor.assumeIsolated { PowerMonitor.shared.powerSourceChanged() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    nonisolated static func readOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    private func powerSourceChanged() {
        let now = Self.readOnBattery()
        guard now != onBattery else { return }
        onBattery = now
        Log.shared.info("power: \(now ? "on battery" : "on mains power")")
        onBatteryChange?(now)
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
