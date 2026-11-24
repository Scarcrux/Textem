import AppKit
import Carbon.HIToolbox

// System-wide Textem shortcuts use Carbon's
// RegisterEventHotKey, which — unlike NSEvent global monitors — needs no
// Accessibility permission and can be registered by any app.
@MainActor
final class GlobalHotkey {
    enum Shortcut {
        case showTextem, copyCode

        var id: UInt32 { self == .showTextem ? 1 : 2 }
        var key: UInt32 { UInt32(self == .showTextem ? kVK_ANSI_M : kVK_ANSI_C) }
        var modifiers: UInt32 { UInt32(self == .showTextem ? cmdKey | optionKey : cmdKey | optionKey | controlKey) }
    }

    private let shortcut: Shortcut
    private let onTrigger: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(shortcut: Shortcut = .showTextem, onTrigger: @escaping () -> Void) {
        self.shortcut = shortcut
        self.onTrigger = onTrigger
    }

    var isRegistered: Bool { hotKeyRef != nil }

    @discardableResult
    func register() -> Bool {
        if isRegistered { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == OSType(0x5458544D) else {
                return OSStatus(eventNotHandledErr)
            }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon hotkey events are delivered on the main thread.
            let id = identifier.id
            return MainActor.assumeIsolated {
                guard hotkey.shortcut.id == id else { return OSStatus(eventNotHandledErr) }
                hotkey.onTrigger()
                return noErr
            }
        }

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard handlerStatus == noErr else {
            NSLog("[Textem] global hotkey handler registration failed: %d", handlerStatus)
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5458544D), id: shortcut.id) // "TXTM"
        let hotkeyStatus = RegisterEventHotKey(
            shortcut.key,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard hotkeyStatus == noErr else {
            NSLog("[Textem] global hotkey is unavailable: %d", hotkeyStatus)
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
