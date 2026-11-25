import SwiftUI

////////////////////
//// Colours for the window menus, app menu and icon badges
/// System colours adapt to Light and Dark mode; badge colours are fixed so
// each action keeps one recognisable colour.

enum MenuPalette {
    // Icon badges
    static let badgeClose = Color(red: 1.0, green: 0.37, blue: 0.34)
    static let badgeHide = Color(red: 1.0, green: 0.73, blue: 0.18)
    static let badgeQuit = Color(red: 0.56, green: 0.43, blue: 0.97)
    static let badgeSymbol = Color.black.opacity(0.62)
    static let badgeStroke = Color.white.opacity(0.85)

    // Window row traffic lights (close reuses badgeClose)
    static let windowMinimize = Color(red: 1.0, green: 0.74, blue: 0.18)
    static let windowZoom = Color(red: 0.16, green: 0.79, blue: 0.25)
    static let windowControlDisabled = Color.primary.opacity(0.18)
    static let windowControlStroke = Color.black.opacity(0.12)

    // Menus
    static let focusFill = Color.accentColor.opacity(0.36)
    static let groupFill = Color.accentColor.opacity(0.16)
    static let hoverFill = Color.primary.opacity(0.14)
    static let runningRing = Color.accentColor
    static let destructive = Color.red
    static let cardStroke = Color.primary.opacity(0.1)
    static let cardShadow = Color.black.opacity(0.28)
    static let stripFill = Color.primary.opacity(0.05)
    static let inactiveAppOpacity = 0.55
}

//////////////////
