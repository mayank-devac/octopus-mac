import Foundation

////////////////////
//// Preference keys for the window menus, sidebar app menu and pinned apps
/// Every UserDefaults key these features read or write lives here.
// Older features keep their keys beside their own settings types.

enum PreferenceKeys {
    /// `SidebarWindowMenuStyle` raw value: the hover menu beside sidebar icons.
    static let sidebarWindowMenuStyle = "sidebarWindowMenuStyle"
    /// Bool, default off: the sidebar's Modern window menu also lists open apps outside the workspace.
    static let sidebarWindowMenuShowsOpenApps = "sidebarWindowMenuShowsOpenApps"
    /// Bool, default off: with open apps shown, the Modern menu drops the workspace's apps and lists only open apps.
    static let sidebarWindowMenuOnlyOpenApps = "sidebarWindowMenuOnlyOpenApps"
    /// Bool, default off: hovering an app in the sidebar menu's strip lists only that app's windows.
    static let sidebarWindowMenuShowsHoveredAppOnly = "sidebarWindowMenuShowsHoveredAppOnly"
    /// `SidebarAppMenuButton` raw value: which button opens the app menu with Control.
    static let sidebarAppMenuButton = "sidebarAppMenuButton"
    /// Bundle identifiers that stay in the sidebar after their app quits.
    static let sidebarPinnedApps = "sidebarPinnedApps"
    /// Most recently used bundle identifiers, newest first.
    static let recentApps = "windowMenuRecentApps"
}

//// Keys are stored as plain strings: renaming one drops the user's saved value.
//////////////////
