//
//  AccessibilityGuidePlacement.swift
//  octopus
//
//  Pure geometry for docking the permission guide panel next to the System Settings window.
//

import CoreGraphics

enum AccessibilityGuidePlacement {
    static let gap: CGFloat = 8

    ////////////////////
    //// Choose the panel origin
    /// Tries below, above, right, then left of the Settings window and takes the first side with room.
    // All rects are AppKit (bottom-left) coordinates; `visibleFrame` is the screen holding the window.
    // The cross axis is clamped to the screen so the panel never hangs off an edge.

    static func origin(panelSize: CGSize, settingsWindow window: CGRect, visibleFrame visible: CGRect) -> CGPoint {
        let centredX = clamp(window.midX - panelSize.width / 2,
                             visible.minX + gap, visible.maxX - panelSize.width - gap)
        let alignedY = clamp(window.minY, visible.minY + gap, visible.maxY - panelSize.height - gap)

        let below = window.minY - panelSize.height - gap
        if below >= visible.minY { return CGPoint(x: centredX, y: below) }

        let above = window.maxY + gap
        if above + panelSize.height <= visible.maxY { return CGPoint(x: centredX, y: above) }

        let right = window.maxX + gap
        if right + panelSize.width <= visible.maxX { return CGPoint(x: right, y: alignedY) }

        let left = window.minX - panelSize.width - gap
        if left >= visible.minX { return CGPoint(x: left, y: alignedY) }

        return CGPoint(x: clamp(window.minX + gap, visible.minX + gap, visible.maxX - panelSize.width - gap),
                       y: alignedY)
    }

    //// Last resort is the window's bottom-left corner: it covers the Settings sidebar,
    //// not the Accessibility list or its +/- buttons on the right.
    //////////////////

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        max(lower, min(value, upper))
    }
}
