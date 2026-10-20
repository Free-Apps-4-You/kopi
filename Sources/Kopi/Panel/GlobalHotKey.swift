import Carbon.HIToolbox
import Foundation
import KopiCore

/// Global shortcut through Carbon's hot key API.
///
/// Carbon delivers the press to this process alone, so the shortcut works while another
/// application is frontmost and needs no accessibility permission — unlike an event
/// monitor, which macOS would gate behind one.
@MainActor
final class GlobalHotKey {
    /// Four character code identifying Kopi's hot key.
    nonisolated static let signature: OSType = 0x564C5059  // 'VLPY'
    private let identifier: UInt32

    init(identifier: UInt32 = 1) { self.identifier = identifier }

    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var handlerRef: EventHandlerRef?
    private var registered: HotkeyDefinition?
    private var onRelease: (() -> Void)?
    private var onPress: (() -> Void)?

    var isRegistered: Bool { hotKeyRef != nil }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    /// Registers `hotkey`, replacing any previous registration. Passing `nil` only
    /// unregisters, which is what the Settings toggle does.
    @discardableResult
    func register(_ hotkey: HotkeyDefinition?, onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) -> Bool {
        self.onPress = onPress
        self.onRelease = onRelease
        guard let hotkey, hotkey.isValid else {
            unregister()
            return false
        }
        if hotKeyRef != nil, registered == hotkey {
            return true
        }
        unregister()
        installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let instanceID = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            hotkey.modifiers.carbonValue,
            instanceID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        hotKeyRef = reference
        registered = hotkey
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        registered = nil
    }

    /// Called from the Carbon handler, on the main thread of the event loop.
    func hotKeyPressed(_ identifier: EventHotKeyID, released: Bool = false) -> Bool {
        guard identifier.signature == Self.signature, identifier.id == self.identifier else { return false }
        if released { onRelease?() } else { onPress?() }
        return true
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { nextHandler, event, userData in
                kopiHotKeyHandler(nextHandler: nextHandler, event: event, userData: userData)
            },
            2,
            &eventTypes,
            pointer,
            &reference
        )
        guard status == noErr else { return }
        handlerRef = reference
    }
}

/// Carbon calls this on the main thread of the application's event loop. Only the hot
/// key identifier crosses into the main actor, and it is plain data.
private func kopiHotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == GlobalHotKey.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
    return MainActor.assumeIsolated {
        hotKey.hotKeyPressed(identifier, released: released) ? noErr : OSStatus(eventNotHandledErr)
    }
}
