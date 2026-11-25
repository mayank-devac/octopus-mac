//
//  MacJiKeys.swift
//  octopus
//
//  Maps raw key presses from the MacJi event tap to tracker input and,
//  while the panel is open, to panel actions that are kept from the app.
//

import AppKit
import Carbon

/// Panel actions; these keys are consumed instead of reaching the app.
enum MacJiKeyAction: Equatable {
    case move(MenuKey)
    /// Return: replace "::term" with the selected emoji.
    case insert
    /// Shift-Return: copy the selected emoji and leave the text as typed.
    case copy
    /// Esc: close and leave the text as typed.
    case close

    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        guard let key = MenuKey(keyCode: keyCode) else { return nil }
        switch key {
        case .up, .down, .left, .right:
            guard modifiers.isEmpty else { return nil }
            self = .move(key)
        case .confirm:
            if modifiers.isEmpty { self = .insert }
            else if modifiers == .shift { self = .copy }
            else { return nil }
        case .cancel:
            self = .close
        }
    }
}

extension MacJiTypedKey {
    /// Command/Control shortcuts, navigation keys and Option-Delete can move the
    /// caret or edit text out of view, so they reset the buffer.
    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String) {
        let modifiers = modifiers.intersection([.command, .option, .control])
        if !modifiers.isDisjoint(with: [.command, .control]) {
            self = .reset
        } else if keyCode == UInt16(kVK_Delete) {
            self = modifiers.isEmpty ? .deleteBackward : .reset
        } else if !characters.isEmpty,
                  !characters.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            self = .text(characters)
        } else {
            self = .reset
        }
    }
}
