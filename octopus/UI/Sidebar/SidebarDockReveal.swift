import AppKit
import SwiftUI

// Dock style opens like the Mac notch: the bar grows out of the screen edge from a thin
// sliver, then the icons settle in. Closing shrinks it back before the panel is removed.
enum SidebarDockReveal {
    static let closedWidth: CGFloat = 4
    static let closedHeightFraction: CGFloat = 0.5
    // Icons start slightly toward the edge so they appear to come out with the bar.
    static let closedContentOffset: CGFloat = 14
    // Matches the close spring below so the panel is ordered out once the bar is gone.
    static let closeDuration: TimeInterval = 0.22

    static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.72)
    static let closeAnimation = Animation.spring(response: 0.22, dampingFraction: 1)

    // Compact mode closes into a slim edge pill: each icon shrinks to the pill's size and centre.
    static let stripWidth: CGFloat = 22
    static let stripIconScale = 16 / SidebarLayout.iconSize
    // Compact mode opens a slimmer Dock with smaller icons than the other Dock modes.
    static let compactBarWidth: CGFloat = 44
    static let compactIconScale = 30 / SidebarLayout.iconSize
    // Open Dock icons sit centred in the bar, which hugs the screen edge, instead of in the wider panel column.
    static func edgeShift(barWidth: CGFloat) -> CGFloat { (SidebarLayout.width - barWidth) / 2 }
    // Moves icons from the open bar's centre to the strip's centre, whichever bar width is in use.
    static func stripIconShift(barWidth: CGFloat) -> CGFloat { (barWidth - stripWidth) / 2 }
    // Separator lines wait for the bar to finish growing and leave before it shrinks.
    static let separatorOpenAnimation = Animation.easeOut(duration: 0.15).delay(0.2)
    static let separatorCloseAnimation = Animation.easeIn(duration: 0.08)

    // `strip` keeps the closed bar visible at full height as Compact mode's edge pill.
    static func barSize(full: CGSize, isOpen: Bool, strip: Bool = false) -> CGSize {
        guard !isOpen else { return full }
        if strip { return CGSize(width: min(stripWidth, full.width), height: full.height) }
        return CGSize(width: min(closedWidth, full.width), height: full.height * closedHeightFraction)
    }

    // The Mac Notch bar starts as the notch itself, then widens and drops to full size.
    static func notchBarSize(full: CGSize, isOpen: Bool, notch: CGSize) -> CGSize {
        guard !isOpen else { return full }
        return CGSize(width: min(notch.width, full.width), height: min(notch.height, full.height))
    }

    // Radius of the concave fillets that blend the open bar into the screen top beside the notch.
    static let notchFlareRadius: CGFloat = 12
}

// Vertical Dock geometry for the sidebar's current state, kept pure so the view only applies it.
struct SidebarDockMetrics {
    let side: SidebarSide
    let showsTitles: Bool
    let isCompact: Bool
    // Compact Dock has no separate number strip: the closed Dock is the strip, and its icons grow in place.
    let isCompactDock: Bool
    let isOpen: Bool
    let rowHeight: CGFloat

    var isStripClosed: Bool { isCompactDock && !isOpen }

    // The icon column is shifted to the edge (see `contentOffset`), so the bar is just wide enough for it.
    var barWidth: CGFloat {
        if showsTitles { return SidebarLayout.dockTitledBarWidth }
        return isCompactDock ? SidebarDockReveal.compactBarWidth : SidebarLayout.dockBarWidth
    }

    // Keeps separator lines inside the bar's rounded edges, whichever bar width is in use.
    var separatorInset: CGFloat {
        SidebarLayout.dockSeparatorInset + (SidebarLayout.dockBarWidth - barWidth) / 2
    }

    var iconScale: CGFloat {
        if isStripClosed { return SidebarDockReveal.stripIconScale }
        return isCompactDock ? SidebarDockReveal.compactIconScale : 1
    }

    // The closed strip moves each icon to the strip's centre. It also hides titles, so a titled
    // row centres its icon vertically instead of leaving the title gap below it.
    var stripIconOffset: CGSize {
        guard isStripClosed else { return .zero }
        let shift = SidebarDockReveal.stripIconShift(barWidth: barWidth)
        return CGSize(width: side == .right ? shift : -shift,
                      height: showsTitles ? (rowHeight - SidebarLayout.iconSlotHeight) / 2 : 0)
    }

    // Moves the icon column toward the screen edge so it is centred in the bar; the closed
    // non-compact Dock tucks it a little further in while the bar is a sliver.
    var contentOffset: CGFloat {
        let tuckedIn = !isCompact && !isOpen ? SidebarDockReveal.closedContentOffset : 0
        let shift = SidebarDockReveal.edgeShift(barWidth: barWidth) + tuckedIn
        return side == .right ? shift : -shift
    }
}
