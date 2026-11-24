import AppKit
import Carbon.HIToolbox

// System-wide Textem shortcuts use Carbon's
// RegisterEventHotKey, which — unlike NSEvent global monitors — needs no
// Accessibility permission and can be registered by any app.
@MainActor
final class GlobalHotkey {
    struct Shortcut: Equatable, Codable {
        static let showTextem = Self(key: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | optionKey), letter: "M")
        static let copyCode = Self(key: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | optionKey | controlKey), letter: "C")
        private static let preferenceKey = "globalCopyCodeShortcut"

        let key: UInt32
        let modifiers: UInt32
        let letter: String

        var label: String {
            [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
                .compactMap { modifiers & UInt32($0.0) != 0 ? $0.1 : nil }.joined() + letter
        }

        func matches(_ other: Self) -> Bool {
            key == other.key && modifiers == other.modifiers
        }

        static func captured(from event: NSEvent) -> Self? {
            let flags = event.modifierFlags.intersection([.command, .control, .shift, .option])
            guard flags.rawValue.nonzeroBitCount >= 2,
                  flags.contains(.command) || flags.contains(.control),
                  let letter = event.characters(byApplyingModifiers: [])?.uppercased(), letter.count == 1,
                  letter.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { return nil }
            let modifiers = [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey),
                             (.shift, shiftKey), (.command, cmdKey)]
                .reduce(0) { $0 | (flags.contains($1.0) ? UInt32($1.1) : 0) }
            return Self(key: UInt32(event.keyCode), modifiers: modifiers, letter: letter)
        }

        static func savedCopyCode(in defaults: UserDefaults = .standard) -> Self {
            guard let data = defaults.data(forKey: preferenceKey),
                  let shortcut = try? JSONDecoder().decode(Self.self, from: data) else { return .copyCode }
            return shortcut
        }

        func saveCopyCode(in defaults: UserDefaults = .standard) {
            defaults.set(try? JSONEncoder().encode(self), forKey: Self.preferenceKey)
        }
    }

    private static var nextID: UInt32 = 0
    private let id: UInt32
    let shortcut: Shortcut
    private let onTrigger: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(shortcut: Shortcut = .showTextem, onTrigger: @escaping () -> Void) {
        Self.nextID &+= 1
        id = Self.nextID
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
                guard hotkey.id == id else { return OSStatus(eventNotHandledErr) }
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

        let hotKeyID = EventHotKeyID(signature: OSType(0x5458544D), id: id) // "TXTM"
        let hotkeyStatus = RegisterEventHotKey(
            shortcut.key,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            shortcut.matches(.showTextem) ? 0 : OptionBits(kEventHotKeyExclusive),
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
