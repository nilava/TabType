import AppKit
import CoreGraphics

/// Monitors keyboard events system-wide via a `CGEventTap`.
///
/// - Reports typed characters and edits so the engine can maintain a context buffer
///   and know when to (re)predict.
/// - Intercepts the **accept key** (Tab by default) *only when a suggestion is
///   currently visible*, swallowing the event so the app can insert the completion
///   instead. When no suggestion is showing, Tab passes through untouched.
///
/// Requires Accessibility permission (the tap is a `.cgSessionEventTap`).
/// How the engine wants a control key handled.
enum ControlDecision {
    case swallow      // consume the event (we acted on it)
    case passthrough  // let it reach the app, but don't treat it as a text edit
    case passthroughStrippingOption  // like passthrough, but remove ⌥ from the event
                                     // (⌥Tab = "send a REAL Tab" while a ghost is up)
    case notControl   // not a control key — proceed to text handling
}

final class KeystrokeMonitor {

    /// Called first for every keyDown. The engine maps the key against configured
    /// shortcut bindings / navigation and returns how to handle it.
    var handleControlKey: ((_ keyCode: Int64, _ flags: CGEventFlags) -> ControlDecision)?

    /// Called for text keydowns with the resolved characters (empty for non-text).
    /// `isDeletion` is true for delete/backspace.
    var onEdit: ((_ characters: String, _ isDeletion: Bool, _ keyCode: Int64) -> Void)?

    /// Keys acted on through system hotkeys (`HotKeyCenter`) — the tap leaves
    /// them alone entirely.
    var isHotKey: ((_ keyCode: Int64, _ flags: CGEventFlags) -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Key codes
    private let kVK_Delete: Int64 = 51        // backspace
    private let kVK_ForwardDelete: Int64 = 117

    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,           // observe only: never delays or drops a key (Cotypist)
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeystrokeMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable if the system disabled our tap (e.g. after a timeout).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // Ignore events we synthesized ourselves when inserting an accepted
        // suggestion — otherwise they'd look like the user typing.
        if event.getIntegerValueField(.eventSourceUserData) == TextInserter.injectedMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Shortcuts are hotkeys now; the tap only observes the rest.
        if isHotKey?(keyCode, flags) == true { return Unmanaged.passUnretained(event) }
        // Navigation and other control keys: observed (they clear a suggestion,
        // remember a sent message…), never consumed.
        if (handleControlKey?(keyCode, flags) ?? .notControl) != .notControl {
            return Unmanaged.passUnretained(event)
        }

        let hasCommandLike = flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
        let isDeletion = keyCode == kVK_Delete || keyCode == kVK_ForwardDelete

        // Resolve typed characters.
        var chars = ""
        if !isDeletion && !hasCommandLike {
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
            if length > 0 { chars = String(utf16CodeUnits: buffer, count: length) }
        }

        onEdit?(chars, isDeletion, keyCode)
        return Unmanaged.passUnretained(event)
    }
}
