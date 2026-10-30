import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Registered through Carbon, which needs no accessibility permission.
@MainActor
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate let action: () -> Void

    /// Returns nil if the shortcut can't be registered, e.g. because another app already owns it.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyPressed, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        let id = EventHotKeyID(signature: OSType(0x5454_524B), id: 1) // "TTRK"
        guard installed == noErr,
              RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
        else { return nil }
    }
}

private func hotKeyPressed(_: EventHandlerCallRef?, _: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.action() }
    return noErr
}
