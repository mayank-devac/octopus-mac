//
//  EmojiPickerKeys.swift
//  octopus
//
//  Maps key presses in the emoji popover to picker actions. Anything not
//  listed (letters, Delete, Command shortcuts) goes to the search field, so
//  typing searches straight away.
//

import AppKit

enum EmojiPickerKeyAction: Equatable {
    case move(MenuKey)
    case nextCategory, previousCategory
    /// Copy the selection; `keepOpen` is Option-Return.
    case copy(keepOpen: Bool)
    /// Clears the search first, then closes on a second press.
    case cancel

    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        if keyCode == 48 {
            guard modifiers.isSubset(of: .shift) else { return nil }
            self = modifiers.contains(.shift) ? .previousCategory : .nextCategory
            return
        }
        guard let key = MenuKey(keyCode: keyCode) else { return nil }
        switch key {
        // Modified arrows (e.g. Option-Left) keep editing the search text.
        case .up, .down, .left, .right:
            guard modifiers.isEmpty else { return nil }
            self = .move(key)
        case .confirm:
            guard modifiers.isSubset(of: .option) else { return nil }
            self = .copy(keepOpen: modifiers.contains(.option))
        case .cancel:
            self = .cancel
        }
    }
}
