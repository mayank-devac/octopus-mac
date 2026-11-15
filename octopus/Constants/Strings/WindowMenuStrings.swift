import Foundation

////////////////////
//// User-facing text for the centre and sidebar window menus
/// Both menus share one view, so they share one string table.

enum WindowMenuStrings {
    static let accessibilityLabel = "Window menu"
    static let loading = "Loading windows…"
    static let needsPermission = "Allow Accessibility access to list windows"
    static let allowAccess = "Allow Access…"
    static let noWindows = "No open windows"
    static let recentEmpty = "Recently quit apps appear here"
    static let openAppsWorkspace = "Open apps"
    static let moreApps = "More apps"
    static let moreWindows = "More windows"
    static let minimised = "Minimised"

    static func showWorkspace(_ name: String) -> String { "Show \(name)" }
    static func openApp(_ title: String) -> String { "Open \(title)" }
    static func focusWindow(_ title: String) -> String { "Focus \(title)" }
    static func runningApp(_ title: String) -> String { "\(title), running" }

    // Preferences > Sidebar
    static let styleTitle = "Window menu"
    static let styleModern = "Modern"
    static let styleClassic = "Classic"
    static let styleHelp = "Modern shows the workspace apps and all their windows. Classic lists only the hovered app's windows."
    static let showsOpenAppsTitle = "Show open apps in window menu"
    static let showsOpenAppsHelp = "Off shows only the workspace's apps. On also lists every other app with open windows."
    static let singleWindowModernHelp = "The Modern window menu always opens, so it can show the whole workspace."
}

//////////////////
