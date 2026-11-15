import AppKit

////////////////////
//// Which mouse button opens the sidebar app menu (always with Control held)
/// Control-click is the macOS context-menu gesture, so plain clicks stay free
/// for the hide / minimise click bindings. A click binding equal to this one
// is skipped by the sidebar; the recorder refuses to assign it.

enum SidebarAppMenuButton: String, CaseIterable {
    case left, right

    static let defaultButton: Self = .left

    var shortcut: MouseShortcut {
        MouseShortcut(button: self == .left ? 0 : 1, modifiers: .control)
    }

    var title: String {
        switch self {
        case .left: return ShortcutPreferenceStrings.appMenuLeft
        case .right: return ShortcutPreferenceStrings.appMenuRight
        }
    }

    static func read(in defaults: UserDefaults) -> Self {
        defaults.string(forKey: PreferenceKeys.sidebarAppMenuButton).flatMap(Self.init(rawValue:)) ?? defaultButton
    }
}

//////////////////
