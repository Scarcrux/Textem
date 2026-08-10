import AppKit
import Carbon.HIToolbox

// A system-wide hotkey (⌥⌘M) to show/hide Textem. Uses Carbon's
// RegisterEventHotKey, which — unlike NSEvent global monitors — needs no
// Accessibility permission and can be registered by any app.
@MainActor
final class GlobalHotkey {
    private let onTrigger: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon hotkey events are delivered on the main thread.
            MainActor.assumeIsolated { hotkey.onTrigger() }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x5458544D), id: 1) // "TXTM"
        RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
