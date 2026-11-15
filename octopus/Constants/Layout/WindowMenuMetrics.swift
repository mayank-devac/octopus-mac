import CoreGraphics

////////////////////
//// Sizes for the shared window menu card (centre and sidebar)
/// `WindowMenuLayout` turns these into the panel size, so the view and the
// panel always agree. Change a value here, not in the view.

enum WindowMenuMetrics {
    // Card
    static let sidebarWidth: CGFloat = 330
    static let centerWidth: CGFloat = 420
    static let cornerRadius: CGFloat = 16
    static let padding: CGFloat = 10
    static let sectionSpacing: CGFloat = 8
    /// Transparent margin around the card so its soft shadow is not clipped by the panel.
    static let shadowInset: CGFloat = 18
    static let shadowRadius: CGFloat = 14
    static let shadowOffsetY: CGFloat = 6

    /// The centre menu sits this fraction of the screen height above centre, like Spotlight.
    static let centerVerticalBias: CGFloat = 0.08

    // App strips (workspace apps and recent apps)
    static let appIconSize: CGFloat = 30
    static let appCellSize: CGFloat = 42
    static let appCellSpacing: CGFloat = 6
    static let appStripHeight: CGFloat = 50
    static let recentStripHeight: CGFloat = 58
    static let runningRingWidth: CGFloat = 1.5
    static let stripChevronWidth: CGFloat = 18
    static let highlightedAppScale: CGFloat = 1.08
    /// The centre menu's top strip shows this many recently quit apps.
    static let recentAppLimit = 6

    // Workspace switch
    static let workspaceWidth: CGFloat = 24
    static let workspaceItemHeight: CGFloat = 22
    static let workspacePadding: CGFloat = 3

    // Window list
    static let windowRowHeight: CGFloat = 32
    static let windowIconSize: CGFloat = 16
    static let windowCloseWidth: CGFloat = 26
    static let sidebarMaximumRows = 8
    static let centerMaximumRows = 10
    static let emptyListHeight: CGFloat = 52
    static let footerHeight: CGFloat = 16
    static let rowCornerRadius: CGFloat = 7
}

//// Heights add up in `WindowMenuLayout.cardSize`; keep both in step.
//////////////////
