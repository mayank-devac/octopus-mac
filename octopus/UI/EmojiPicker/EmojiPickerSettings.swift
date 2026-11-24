//
//  EmojiPickerSettings.swift
//  octopus
//
//  Preference keys for the emoji picker menu-bar item and its recents list.
//

import Foundation

enum EmojiPickerSettings {
    /// Shows the separate emoji menu-bar item (Preferences > General).
    static let showMenuBarItemKey = "showEmojiMenuBarItem"
    static let recentsKey = "emojiRecents"
    static let recentsLimit = 24

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [showMenuBarItemKey: true])
    }

    /// Moves `emoji` to the front, removing an older copy and trimming to `limit`.
    static func recents(adding emoji: String, to recents: [String], limit: Int = recentsLimit) -> [String] {
        Array(([emoji] + recents.filter { $0 != emoji }).prefix(limit))
    }
}
