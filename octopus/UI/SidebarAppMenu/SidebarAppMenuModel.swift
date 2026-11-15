import Foundation

////////////////////
//// Sidebar app menu: commands, items and the snapshot they are built from
/// The context is a plain copy of one sidebar entry, so the catalogue that
// decides which items appear is pure and testable.

enum SidebarAppMenuCommand: Hashable {
    case focusWindow(SidebarWindowID)
    case open
    case snap(SidebarSnapTarget)
    case moveToDesktop(UInt64)
    case toggleHidden
    case closeWindow
    case togglePin
    case showInFinder
    case quit
}

struct SidebarAppMenuItem: Identifiable, Equatable {
    let command: SidebarAppMenuCommand
    let title: String
    let symbol: String
    var isDestructive = false
    var id: SidebarAppMenuCommand { command }
}

struct SidebarAppMenuSection: Identifiable, Equatable {
    enum Layout { case rows, chips }
    let id: String
    let title: String?
    let layout: Layout
    let items: [SidebarAppMenuItem]
}

//// Snapshot ---------------------------------------------------------------

struct SidebarAppMenuWindow: Equatable {
    let id: SidebarWindowID
    let title: String
    let isMinimized: Bool
}

struct SidebarAppMenuDesktop: Equatable {
    let id: UInt64
    let number: Int
}

struct SidebarAppMenuContext: Equatable {
    let title: String
    let isRunning: Bool
    let isHidden: Bool
    let isPinned: Bool
    /// Only apps with a bundle identifier can be pinned.
    let canPin: Bool
    let hasBundleURL: Bool
    let windows: [SidebarAppMenuWindow]
    /// The window under the icon (its title is the sidebar label); snap, move and close act on it.
    let targetWindow: SidebarWindowID?
    let canCloseTarget: Bool
    /// Desktops the target window may move to.
    let desktops: [SidebarAppMenuDesktop]
}

//// Commands carry IDs only; the sidebar re-reads the live entry before acting.
//////////////////
