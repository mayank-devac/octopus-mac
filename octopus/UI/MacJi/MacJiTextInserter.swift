//
//  MacJiTextInserter.swift
//  octopus
//
//  Replaces the typed "::term" in the focused app: Delete once per typed
//  character, then the emoji as a Unicode key event. The clipboard is left
//  alone. Events carry a marker so the MacJi tap ignores them.
//

import AppKit
import Carbon

enum MacJiTextInserter {
    /// "MacJi" in ASCII; stored in each synthetic event's source user data.
    static let syntheticMarker: Int64 = 0x4D_61_63_4A_69

    static func replace(characterCount: Int, with text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<characterCount {
            post(keyCode: CGKeyCode(kVK_Delete), text: nil, source: source)
        }
        post(keyCode: 0, text: text, source: source)
    }

    ////////////////////
    //// One synthetic key press
    /// Flags are cleared so a still-held Shift never turns Delete into a forward delete.
    // `text` replaces whatever the key code would type.

    private static func post(keyCode: CGKeyCode, text: String?, source: CGEventSource?) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    //// Delivered in order through the HID stream, ahead of later typing.
    //////////////////
}
