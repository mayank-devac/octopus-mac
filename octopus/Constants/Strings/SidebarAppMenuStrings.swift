import Foundation

////////////////////
//// User-facing text for the sidebar app menu (Control-click on an icon)

enum SidebarAppMenuStrings {
    static let accessibilityLabel = "App menu"
    static let open = "Open"
    static let show = "Show"
    static let hide = "Hide"
    static let closeWindow = "Close Window"
    static let pin = "Keep in Sidebar"
    static let unpin = "Remove from Sidebar"
    static let showInFinder = "Show in Finder"
    static let quit = "Quit"
    static let windowsSection = "Windows"
    static let snapSection = "Snap"
    static let desktopSection = "Move to Desktop"
    static let notRunning = "Not running"

    static func windowCount(_ count: Int) -> String { count == 1 ? "1 window" : "\(count) windows" }
    static func moveToDesktop(_ number: Int) -> String { "Move to Desktop \(number)" }
}

//////////////////
