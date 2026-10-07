// Global hotkey through Carbon's RegisterEventHotKey — the same mechanism
// The Carbon API still ships with macOS, needs no Accessibility grant or
// Input Monitoring prompt, and works from inside the App Sandbox.

import Carbon.HIToolbox
import Foundation

final class HotkeyMonitor {
    struct Chord: Equatable, Sendable {
        var keyCode: UInt32
        var modifiers: UInt32

        /// ⌃⌥⌘M — clear of ⌘M (minimise) and ⌥⌘M.
        static let `default` = Chord(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
        )

        var displayString: String {
            Self.modifierSymbols(modifiers) + Self.keyName(keyCode)
        }

        static func modifierSymbols(_ modifiers: UInt32) -> String {
            var text = ""
            if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
            return text
        }

        static func keyName(_ keyCode: UInt32) -> String {
            let names: [Int: String] = [
                kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
                kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
                kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
                kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
                kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
                kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
                kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
                kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
                kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
                kVK_ANSI_8: "8", kVK_ANSI_9: "9",
                kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
                kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
                kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
                kVK_F11: "F11", kVK_F12: "F12",
            ]
            return names[Int(keyCode)] ?? "Key \(keyCode)"
        }
    }

    /// Called on the main thread when the chord is pressed. The event is
    /// consumed, so the keystroke never reaches the front app.
    var onPress: (() -> Void)?

    private static let signature: OSType = 0x4256_4C31 // 'BVL1'
    private static let identifier: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var registeredChord: Chord?

    @discardableResult
    func register(_ chord: Chord) -> Bool {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed),
        )
        let callback: EventHandlerUPP = { _, event, refcon -> OSStatus in
            guard let event, let refcon else { return noErr }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &identifier,
            )
            guard status == noErr,
                  identifier.signature == HotkeyMonitor.signature,
                  identifier.id == HotkeyMonitor.identifier
            else { return noErr }

            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.onPress?()
            return noErr
        }

        var handler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler,
        )
        guard handlerStatus == noErr else { return false }
        handlerRef = handler

        var hotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let registerStatus = RegisterEventHotKey(
            chord.keyCode,
            chord.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKey,
        )
        guard registerStatus == noErr else {
            unregister()
            return false
        }
        hotKeyRef = hotKey
        registeredChord = chord
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        hotKeyRef = nil
        handlerRef = nil
        registeredChord = nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
