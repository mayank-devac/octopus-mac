import Foundation

////////////////////
//// Text for Preferences > Shortcuts: window menu, app menu and modifier rows
/// Each modifier row gets a one-line description under its name.

enum ShortcutPreferenceStrings {
    // Window menu
    static let windowMenuSection = "Window menu"
    static let windowMenuTitle = "Open window menu"
    static let windowMenuDetail = "Shows recently quit apps, workspace apps and their windows in the centre of the screen. Use the arrow keys or pointer, Return to open, Escape to close."
    static let windowMenuTypingWarning = "Shift + Space is also typed in text fields. Choose another shortcut if spaces go missing while you type."

    // App menu
    static let appMenuTitle = "Open app menu"
    static let appMenuLeft = "⌃ + Left click"
    static let appMenuRight = "⌃ + Right click"
    static let appMenuDetail = "Control-click a sidebar icon for its app menu. Hide and minimise keep their own clicks; a click bound to them that matches this one is skipped."
    static let appMenuConflict = "This click opens the sidebar app menu. Choose another shortcut or change the app menu click."

    // Modifier rows
    static let switchAppDetail = "Hold with 1–9 or 0 to open the app bound to that number. Press again to cycle its windows."
    static let openWorkspaceDetail = "Hold with a workspace number to open every app in that workspace."
    static let bindAppDetail = "Hold with 1–9 or 0 to bind the frontmost app to that number."
    static let sidebarAppsDetail = "Hold with 1–9 or 0 to open that sidebar position. Turn on number shortcuts in Sidebar settings."
    static let desktopMapDetail = "Hold and move onto the sidebar to preview desktops. Clear all to turn it off."
}

//////////////////
