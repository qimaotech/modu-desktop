import AppKit
import Carbon

@MainActor final class GlobalShortcutRegistration {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?
    private var isPressed = false

    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws {
        unregister()
        if handler == nil {
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    Unmanaged<GlobalShortcutRegistration>.fromOpaque(context).takeUnretainedValue().handle(event)
                }
            }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                        EventHotKeyID(signature: 0x4D6F6475, id: 1), GetApplicationEventTarget(),
                                        OptionBits(kEventHotKeyExclusive), &hotKey)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        self.action = action
        // Recording can finish while the new shortcut is still held down.
        isPressed = CGEventSource.keyState(.combinedSessionState, key: shortcut.keyCode)
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        action = nil
        isPressed = false
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                      nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr, identifier.signature == 0x4D6F6475, identifier.id == 1, hotKey != nil else { return OSStatus(eventNotHandledErr) }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) { isPressed = false }
        else if !isPressed { isPressed = true; action?() }
        return noErr
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
