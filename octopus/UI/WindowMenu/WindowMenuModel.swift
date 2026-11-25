import Foundation
import CoreGraphics

////////////////////
//// Value types shared by the centre and sidebar window menus
/// The menus never hold AX elements or `Window` objects: the source adapter
/// copies what they show into these snapshots, so building and navigating the
// menu stays pure and testable.

/// An Octopus profile shown as a workspace ("1", "2", …) in the menu's switch.
struct WindowMenuWorkspace: Identifiable, Equatable {
    let id: UUID
    let label: String
    let name: String
    let bundleIdentifiers: [String]
}

/// One app cell in the workspace or recent strip.
struct WindowMenuApp: Identifiable, Equatable {
    /// Bundle identifier, or `pid:<n>` for a running app without one.
    let id: String
    let bundleIdentifier: String?
    let title: String
    let bundleURL: URL?
    /// Nil when the app is not running.
    let pid: pid_t?

    var isRunning: Bool { pid != nil }
}

/// One row in the window list.
struct WindowMenuWindow: Identifiable, Equatable {
    let id: SidebarWindowID
    let appID: String
    let title: String
    let isMinimized: Bool
    let canMinimize: Bool
    let canClose: Bool
}

/// Everything one presentation of the menu shows.
struct WindowMenuContent: Equatable {
    var workspaces: [WindowMenuWorkspace] = []
    var selectedWorkspaceID: UUID?
    var apps: [WindowMenuApp] = []
    /// The first workspace app when opened apps lead the strip; a separator sits before it, nil draws none.
    var firstWorkspaceAppID: String?
    var windows: [WindowMenuWindow] = []
    var recentApps: [WindowMenuApp] = []
}

/// Which apps the strip lists besides the hovered or frontmost app.
enum WindowMenuAppScope: Equatable {
    /// The workspace's apps; open apps only when the workspace has none.
    case workspace
    /// The workspace's apps, then every other app with open windows.
    case workspaceAndOpen
    /// Only apps with open windows.
    case openOnly

    /// Reads the two Preferences checkboxes; "Only opened apps" counts only while "Show" is on.
    static func current(in defaults: UserDefaults = .standard) -> Self {
        guard defaults.bool(forKey: PreferenceKeys.sidebarWindowMenuShowsOpenApps) else { return .workspace }
        return defaults.bool(forKey: PreferenceKeys.sidebarWindowMenuOnlyOpenApps) ? .openOnly : .workspaceAndOpen
    }
}

/// Every hoverable or focusable element; also the key for pointer anchors.
enum WindowMenuTarget: Hashable {
    case recent(String)
    case workspace(UUID)
    case app(String)
    case window(SidebarWindowID)
    /// A traffic-light button on a window row.
    case windowControl(SidebarWindowID, WindowControl)
    case moreApps
    case moreWindows
}

/// What the menu body shows instead of rows while it cannot list windows.
enum WindowMenuStatus: Equatable {
    case ready, loading, needsPermission
}

//// Source snapshots ------------------------------------------------------

/// A running app and its windows, copied from the sidebar inventory.
struct WindowMenuRunningApp: Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let title: String
    let bundleURL: URL?
    var windows: [WindowMenuWindowSnapshot]
}

struct WindowMenuWindowSnapshot: Equatable {
    let windowID: CGWindowID
    let title: String
    let isMinimized: Bool
    let canMinimize: Bool
    let canClose: Bool
}

/// An installed app found on disk by bundle identifier.
struct WindowMenuInstalledApp: Equatable {
    let title: String
    let bundleURL: URL
}

//// Keep these free of AppKit objects so tests can build them directly.
//////////////////
