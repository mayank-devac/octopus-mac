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
    // Every side keeps `gap` from the screen edge, and the cross axis is clamped the same way.

    static func origin(panelSize: CGSize, settingsWindow window: CGRect, visibleFrame visible: CGRect) -> CGPoint {
        let centredX = clamp(window.midX - panelSize.width / 2,
                             visible.minX + gap, visible.maxX - panelSize.width - gap)
        let alignedY = clamp(window.minY, visible.minY + gap, visible.maxY - panelSize.height - gap)

        let below = window.minY - panelSize.height - gap
        if below >= visible.minY + gap { return CGPoint(x: centredX, y: below) }

        let above = window.maxY + gap
        if above + panelSize.height <= visible.maxY - gap { return CGPoint(x: centredX, y: above) }

        let right = window.maxX + gap
        if right + panelSize.width <= visible.maxX - gap { return CGPoint(x: right, y: alignedY) }

        let left = window.minX - panelSize.width - gap
        if left >= visible.minX + gap { return CGPoint(x: left, y: alignedY) }

        return CGPoint(x: clamp(window.minX + gap, visible.minX + gap, visible.maxX - panelSize.width - gap),
                       y: alignedY)
    }

    //// Last resort is the window's bottom-left corner: it covers the Settings sidebar,
    //// not the Accessibility list or its +/- buttons on the right.
    //////////////////

    // The screen with the largest overlap, so a window crossing onto a second display stays on its main one.
    static func screenIndex(containingMostOf window: CGRect, screenFrames: [CGRect]) -> Int? {
        let overlaps = screenFrames.map { frame -> CGFloat in
            let shared = frame.intersection(window)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else { return nil }
        return best
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        max(lower, min(value, upper))
    }
}
