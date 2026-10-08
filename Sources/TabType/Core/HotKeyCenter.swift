import AppKit
import Carbon.HIToolbox

/// The keys TabType acts on, as system hotkeys (Carbon `RegisterEventHotKey`),
/// so the keystroke tap can be listen-only (Cotypist's design): a key is taken
/// away from the app only while TabType has something to do with it — Tab only
/// while a suggestion is up, global shortcuts always.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Called on the main thread when a registered binding is pressed.
    var onPress: ((KeyBinding) -> Void)?
    /// Called once per binding that couldn't be registered (another app owns it).
    var onConflict: ((KeyBinding) -> Void)?
    private var reportedConflicts: Set<KeyBinding> = []

    private var registered: [KeyBinding: (ref: EventHotKeyRef, id: UInt32)] = [:]
    private var byID: [UInt32: KeyBinding] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    private init() {}

    /// Whether `keyCode` + `flags` is currently taken by a hotkey.
    func isRegistered(keyCode: Int64, flags: CGEventFlags) -> Bool {
        registered.keys.contains { $0.matches(keyCode: keyCode, flags: flags) }
    }

    /// Make exactly `bindings` the registered hotkeys.
    func setActive(_ bindings: Set<KeyBinding>) {
        installHandlerIfNeeded()
        for (binding, entry) in registered where !bindings.contains(binding) {
            Log.shared.debug("hotkey: released \(binding.displayString)")
            UnregisterEventHotKey(entry.ref)
            registered[binding] = nil
            byID[entry.id] = nil
        }
        for binding in bindings where binding.isSet && registered[binding] == nil {
            let id = nextID
            nextID &+= 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x5442_5459), id: id)   // 'TBTY'
            let status = RegisterEventHotKey(UInt32(binding.keyCode), Self.carbonModifiers(binding.modifiers),
                                             hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[binding] = (ref, id)
                byID[id] = binding
                Log.shared.debug("hotkey: registered \(binding.displayString)")
            } else {
                Log.shared.info("hotkey: could not register \(binding.displayString) (status \(status))")
                if reportedConflicts.insert(binding).inserted { onConflict?(binding) }
            }
        }
    }

    /// Release `binding` for one press (re-posting a key we didn't act on).
    func suspend(_ binding: KeyBinding) {
        guard let entry = registered[binding] else { return }
        UnregisterEventHotKey(entry.ref)
        registered[binding] = nil
        byID[entry.id] = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            MainActor.assumeIsolated {
                let center = HotKeyCenter.shared
                if let binding = center.byID[hotKeyID.id] {
                    Log.shared.debug("hotkey: pressed \(binding.displayString)")
                    center.onPress?(binding)
                }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handler)
    }

    nonisolated static func carbonModifiers(_ raw: UInt64) -> UInt32 {
        let flags = CGEventFlags(rawValue: raw)
        var m: UInt32 = 0
        if flags.contains(.maskCommand) { m |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { m |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { m |= UInt32(optionKey) }
        if flags.contains(.maskControl) { m |= UInt32(controlKey) }
        return m
    }

    /// Send a key we took but didn't act on on to the app, unmarked by the tap.
    nonisolated static func repost(keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)
            else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: TextInserter.injectedMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
