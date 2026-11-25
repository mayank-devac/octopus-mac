//
//  MacJiSettings.swift
//  octopus
//
//  Preference keys for MacJi, the inline emoji panel opened by typing a
//  trigger (default "::") followed by a search term in any app.
//

import Foundation

enum MacJiSettings {
    static let enabledKey = "macJiEnabled"
    static let triggerKey = "macJiTrigger"
    static let defaultTrigger = "::"
    /// Long triggers are hard to type and short-circuit nothing useful.
    static let triggerMaxLength = 4

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [enabledKey: true, triggerKey: defaultTrigger])
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var trigger: String {
        validTrigger(UserDefaults.standard.string(forKey: triggerKey))
    }

    /// Falls back to the default for an empty, too long or whitespace-containing
    /// trigger, or one made of query characters (it would fire inside words).
    static func validTrigger(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw.count <= triggerMaxLength,
              !raw.contains(where: { $0.isWhitespace || $0.isNewline }),
              !raw.allSatisfy(MacJiTriggerTracker.isQueryCharacter)
        else { return defaultTrigger }
        return raw
    }
}
