import CoreGraphics

////////////////////
//// Sizes for the window tab strip panel (`WindowTabStripPanel`)
/// Tab widths come from the title text plus these allowances, so the strip
/// grows and shrinks with the number of open apps. Change a value here,
/// not in the view.

enum WindowTabStripMetrics {
    /// A tab never gets narrower than this, however short its title.
    static let tabMinimumWidth: CGFloat = 180
    /// A tab never gets wider than this, however long its title.
    static let tabMaximumWidth: CGFloat = 245
    /// Icon width inside a tab; the running app's icon is scaled to it.
    static let iconSize: CGFloat = 16
    /// Gap between the tab icon and its title text.
    static let iconTitleGap: CGFloat = 8
    /// Width reserved at the tab's trailing edge for the close control.
    static let closeButtonWidth: CGFloat = 22
    /// Horizontal padding added around a tab's content when measuring.
    static let edgePadding: CGFloat = 12
    /// Inset applied to each tab's frame inside the row.
    static let tabInset: CGFloat = 3
    /// Width of the leading drag grip ("≡") area.
    static let gripWidth: CGFloat = 28

    /// Everything added to the measured text width to size a tab.
    static var contentAllowance: CGFloat {
        iconSize + iconTitleGap + closeButtonWidth + edgePadding
    }
}

////////////////////
