import SwiftUI

////////////////////
//// Shared animation curves for the window menus, app menu and icon badges
/// A lightly under-damped spring gives the "wobble" on appear without bouncing.
// Reduce Motion is honoured by the views that use these values.

enum MenuMotion {
    // Appear
    static let appear = Animation.spring(response: 0.34, dampingFraction: 0.68)
    static let appearScale: CGFloat = 0.92

    // Hover / selection
    static let highlight = Animation.spring(response: 0.26, dampingFraction: 0.84)
    static let hoverGrow = Animation.spring(response: 0.22, dampingFraction: 0.6)
    static let press = Animation.easeOut(duration: 0.1)
    static let pressedScale: CGFloat = 0.94

    // Dismiss
    static let fadeOutDuration: TimeInterval = 0.12
    /// A chosen menu item flashes briefly before the menu closes, like a native menu.
    static let commandFlashDelay: TimeInterval = 0.08
    /// The app menu closes this long after the pointer leaves it (once it has been inside).
    static let autoCloseDelay: TimeInterval = 0.8
}

//////////////////
