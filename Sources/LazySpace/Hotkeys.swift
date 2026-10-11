import Carbon
import Foundation

/// Global shortcuts via Carbon RegisterEventHotKey (public API, no Accessibility needed, does not swallow other input).
final class Hotkeys {
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var bindings: [HotkeyBinding]
    private let onCommand: (HotkeyBinding.Action, String, Date) -> Void
    private(set) var failed: [String] = []
    /// Combinations actually registered. The input monitor treats them as commands to this app.
    private(set) var registered: [HotkeyBinding] = []

    init(bindings: [HotkeyBinding], onCommand: @escaping (HotkeyBinding.Action, String, Date) -> Void) {
        self.bindings = bindings
        self.onCommand = onCommand
    }

    /// On a settings change: unregister everything and register again.
    func replace(_ newBindings: [HotkeyBinding]) -> Int {
        unregister()
        bindings = newBindings
        return register()
    }

    func register() -> Int {
        // Installing twice would leave the old handler and registrations behind.
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let me = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            let index = Int(hotKeyID.id)
            if index < me.bindings.count {
                let b = me.bindings[index]
                let pressed = Date()
                DispatchQueue.main.async { me.onCommand(b.action, "hotkey \(b.display)", pressed) }
            }
            return noErr
        }, 1, &spec, selfPtr, &handler)

        failed = []
        registered = []
        for (i, b) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4C5A5350) /* LZSP */, id: UInt32(i))
            if RegisterEventHotKey(b.keyCode, b.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr { registered.append(b) } else { failed.append(b.display) }
            refs.append(ref)
        }
        return registered.count
    }

    /// The Carbon handler does not retain self, so always unregister before deallocation.
    deinit { unregister() }

    func unregister() {
        for r in refs { if let r { UnregisterEventHotKey(r) } }
        refs.removeAll()
        registered = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
