import AppKit

////////////////////
//// Sidebar geometry
/// Sizes and frame math for the sidebar panel, Mac Notch bar, menus and pointer triggers.
// Pure functions of screen frames and settings, so they are covered by geometry tests.

enum SidebarLayout {
    static func scrolledPosition(_ position: Double, deltaY: Double, precise: Bool,
                                 inverted: Bool, availableTravel: CGFloat) -> Double? {
        guard position.isFinite, deltaY.isFinite, deltaY != 0,
              availableTravel.isFinite, availableTravel > 0 else { return nil }
        // Wheel events use lines; high-resolution devices already report points.
        // Undo Natural Scrolling so rolling the wheel up moves the sidebar up.
        let distance = deltaY * (inverted ? -1 : 1) * (precise ? 1 : 8)
        guard distance.isFinite else { return nil }
        return min(1, max(0, position - distance / Double(availableTravel)))
    }

    // Keep the icon close to the display edge while leaving room for its label.
    static let width: CGFloat = 86
    // Horizontal slots need less label space, while retaining the enlarged icon's width.
    static let notchItemWidth: CGFloat = 64
    static let compactWidth: CGFloat = 20
    static let notchTriggerHeight: CGFloat = 10
    static let virtualNotchWidthRatio: CGFloat = 0.13
    static let virtualNotchHeightRatio: CGFloat = 0.033
    static let virtualNotchWidthRange: ClosedRange<CGFloat> = 160...240
    static let virtualNotchHeightRange: ClosedRange<CGFloat> = 24...36
    static let notchBarMaximumScreenFraction: CGFloat = 0.72
    static let notchBarPadding: CGFloat = 8
    static let notchMonitorWidth: CGFloat = 40
    static let notchCloseDelay: TimeInterval = 0.25
    static let notchWindowMenuOffset: CGFloat = 40
    static let notchWindowMenuWidth: CGFloat = 220
    static let notchEmptyWidth: CGFloat = 40
    static let notchSeparatorWidth: CGFloat = 12
    // Extra canvas toward the desktop for the magnified frost's soft edges.
    static let drawingPadding: CGFloat = 36
    static let menuGap: CGFloat = 2
    // Keep the icon and title close together so the sidebar reads as a compact dock.
    static let rowHeight: CGFloat = 86
    // Without window titles, each row needs just the enlarged icon's height.
    static let iconOnlyRowHeight: CGFloat = 46
    static let dockBarWidth: CGFloat = 58
    // A titled Dock bar is wide enough to wrap titles like the Floating sidebar does.
    static let dockTitledBarWidth: CGFloat = 70
    static let badgeFontSize: CGFloat = 9
    static let badgeMinimumWidth: CGFloat = 15
    static let dockCornerRadius: CGFloat = 16
    // Keeps separator lines within the dock bar's rounded edges.
    static let dockSeparatorInset: CGFloat = 20
    static let desktopSeparatorHeight: CGFloat = 12
    // The Dock's line has no frost behind it, so it needs less room than the Floating separator.
    static let dockSeparatorHeight: CGFloat = 6
    // Space above and below a visible Dock display line, as a share of the app spacing.
    static let dockSeparatorGapRatio: CGFloat = 0.90
    // Moves gap from below each Dock line (display and Desktop) to above it: the icon below carries its own slot inset,
    // while the label above ends flush, so equal gaps look top-heavy. Total height is unchanged.
    static let dockSeparatorOpticalShift: CGFloat = 6
    // Fills more of the fixed icon slot, so row spacing is unchanged.
    static let iconSize: CGFloat = 44
    static let iconSlotHeight: CGFloat = 46
    static let labelHeight: CGFloat = 40
    static let titleVerticalPadding: CGFloat = 2
    // Vertical Dock titles move up into the icon slot's spare bottom margin, closer to their icon.
    static let dockTitleLift: CGFloat = 3
    static let titleLineLimit = 2

    // All title lines of the medium-weight title font, plus their padding above and below.
    static func titleHeight(fontSize: Double) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .medium)
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        return lineHeight * CGFloat(titleLineLimit) + titleVerticalPadding * 2
    }
    static let magnificationGrowth: CGFloat = 0.32
    /// Hover lift for the icons directly above and below the magnified one.
    static let neighborMagnificationGrowth: CGFloat = 0.04
    static let verticalPadding: CGFloat = 4
    static let menuRowHeight: CGFloat = 34
    static let menuPadding: CGFloat = 4
    static let menuActionHeight: CGFloat = 34
    static let menuWindowActionWidth: CGFloat = 30

    static var appSpacing: CGFloat {
        CGFloat(min(max(UserDefaults.standard.double(forKey: "sidebarAppSpacing"), 0),
                    SidebarSettingsValues.maximumAppSpacing))
    }

    static func sidebarFrame(in visibleFrame: CGRect, count: Int, side: SidebarSide, position: Double,
                             appSpacing: CGFloat = SidebarLayout.appSpacing, separatorCount: Int = 0,
                             contentHeight: CGFloat? = nil, minimumHeight: CGFloat = rowHeight,
                             itemHeight: CGFloat = rowHeight) -> CGRect {
        let separators = CGFloat(max(0, separatorCount)) * (desktopSeparatorHeight + appSpacing)
        let height = min(max(minimumHeight,
            contentHeight ?? (listContentHeight(count: count, appSpacing: appSpacing, itemHeight: itemHeight) + separators)),
            visibleFrame.height)
        let width = min(Self.width, visibleFrame.width)
        return CGRect(
            x: side == .left ? visibleFrame.minX : visibleFrame.maxX - width,
            y: visibleFrame.minY + (visibleFrame.height - height) * (1 - min(1, max(0, position))),
            width: width, height: height
        )
    }

    // Height of a plain list of rows with no Desktop or display headers.
    static func listContentHeight(count: Int, appSpacing: CGFloat, itemHeight: CGFloat = rowHeight) -> CGFloat {
        CGFloat(count) * itemHeight + CGFloat(max(0, count - 1)) * appSpacing + 16
    }

    static func compactContentHeight(count: Int, appSpacing: CGFloat, itemHeight: CGFloat = rowHeight) -> CGFloat {
        guard count > 0 else { return itemHeight }
        let numberSlots = CGFloat(count) * iconSlotHeight
        let gaps = CGFloat(count - 1) * (max(0, itemHeight - iconSlotHeight) + appSpacing)
        return numberSlots + gaps + verticalPadding * 2
    }

    static func menuFrame(size: CGSize, icon: CGRect, screen: CGRect, side: SidebarSide) -> CGRect {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let x = side == .left ? icon.maxX + menuGap : icon.minX - menuGap - width
        let y = icon.midY - height / 2 - 18
        return CGRect(
            x: min(max(x, screen.minX), screen.maxX - width),
            y: min(max(y, screen.minY), screen.maxY - height),
            width: width, height: height
        )
    }

    // The number strip stays at the display edge; the app column opens toward the desktop.
    static func compactFrames(beside frame: CGRect, side: SidebarSide, expanded: Bool,
                              stripWidth: CGFloat = compactWidth) -> (main: CGRect, compact: CGRect, panel: CGRect) {
        let compact = CGRect(x: side == .left ? frame.minX : frame.maxX - stripWidth,
                             y: frame.minY, width: stripWidth, height: frame.height)
        let main = frame.offsetBy(dx: side == .left ? stripWidth : -stripWidth, dy: 0)
        let drawing = CGRect(x: side == .left ? main.minX : main.minX - drawingPadding,
                             y: main.minY, width: main.width + drawingPadding, height: main.height)
        return (main, compact, expanded ? drawing.union(compact) : compact)
    }

    // A hardware notch gets a small extension; other Macs get a proportional top-centre notch.
    static func hardwareNotchFrame(screenFrame: CGRect, safeTopInset: CGFloat,
                                   leftArea: CGRect?, rightArea: CGRect?) -> CGRect? {
        guard safeTopInset.isFinite, safeTopInset > 0, let leftArea, let rightArea else { return nil }
        let minX = max(screenFrame.minX, leftArea.maxX)
        let maxX = min(screenFrame.maxX, rightArea.minX)
        let y = screenFrame.maxY - safeTopInset - notchTriggerHeight
        guard minX.isFinite, maxX.isFinite, y.isFinite, maxX > minX, y >= screenFrame.minY else { return nil }
        return CGRect(x: minX, y: y, width: maxX - minX, height: notchTriggerHeight)
    }

    ////////////////////
    //// Edge trigger
    /// A free screen edge stops the pointer, so a thin on-screen strip is enough to rest in.
    // An edge shared with another display has no wall: the pointer slides onto the neighbour,
    // so a delayed reveal could never fire. There the strip widens, but only on its own display:
    // the display under the pointer decides which sidebar opens.

    static let edgeTriggerWidth: CGFloat = 3
    static let seamTriggerWidth: CGFloat = 12

    static func edgeTriggerFrame(side: SidebarSide, screenFrame: CGRect, minY: CGFloat, height: CGFloat,
                                 widensAtSeam: Bool, allScreenFrames: [CGRect]) -> CGRect {
        let seamX = side == .left ? screenFrame.minX : screenFrame.maxX
        let sharesSeam = allScreenFrames.contains { other in
            other != screenFrame && abs((side == .left ? other.maxX : other.minX) - seamX) < 0.5
                && other.minY < minY + height && other.maxY > minY
        }
        let width = widensAtSeam && sharesSeam ? seamTriggerWidth : edgeTriggerWidth
        return CGRect(x: side == .left ? screenFrame.minX : screenFrame.maxX - width,
                      y: minY, width: width, height: height)
    }

    //// A pointer resting just inside its own display at the seam now opens that display's sidebar.
    //////////////////

    // A pointer pushed against the top edge reports y == screen maxY, which half-open
    // CGRect hit tests treat as outside the notch and the Dock bar. Move it onto the top row,
    // unless a display stacked above actually owns that point.
    static func pointerHitPoint(_ point: CGPoint, screenFrame: CGRect, allScreenFrames: [CGRect]) -> CGPoint {
        guard point.y == screenFrame.maxY, point.x >= screenFrame.minX, point.x < screenFrame.maxX,
              !allScreenFrames.contains(where: { $0.contains(point) }) else { return point }
        return CGPoint(x: point.x, y: screenFrame.maxY - 0.5)
    }

    static func notchTriggerFrame(screenFrame: CGRect, safeTopInset: CGFloat,
                                  leftArea: CGRect?, rightArea: CGRect?, virtualWidth: CGFloat? = nil) -> CGRect? {
        guard screenFrame.width.isFinite, screenFrame.height.isFinite,
              screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        if let hardware = hardwareNotchFrame(screenFrame: screenFrame, safeTopInset: safeTopInset,
                                             leftArea: leftArea, rightArea: rightArea) {
            return hardware
        }
        let automaticWidth = min(max(screenFrame.width * virtualNotchWidthRatio,
                            virtualNotchWidthRange.lowerBound), virtualNotchWidthRange.upperBound)
        let requestedWidth = virtualWidth.flatMap { $0.isFinite ? $0 : nil } ?? automaticWidth
        let width = min(screenFrame.width, max(0, requestedWidth))
        let height = min(max(screenFrame.height * virtualNotchHeightRatio,
                             virtualNotchHeightRange.lowerBound), virtualNotchHeightRange.upperBound)
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height,
                      width: width, height: height)
    }

    // `topExtension` stretches the content up from the notch to the screen top, so the Dock bar
    // can start as the notch itself and widen from there.
    static func notchSidebarFrames(contentSize: CGSize, below notch: CGRect, availableFrame: CGRect,
                                   topExtension: CGFloat = 0) -> (content: CGRect, panel: CGRect) {
        let width = min(max(0, contentSize.width), availableFrame.width)
        let availableHeight = max(0, notch.minY - availableFrame.minY)
        let barHeight = min(max(0, contentSize.height), availableHeight)
        let height = barHeight + max(0, topExtension)
        let x = min(max(notch.midX - width / 2, availableFrame.minX), availableFrame.maxX - width)
        let content = CGRect(x: x, y: notch.minY - barHeight, width: width, height: height)
        let panelWidth = min(width + drawingPadding * 2, availableFrame.width)
        let panelX = min(max(content.midX - panelWidth / 2, availableFrame.minX),
                         availableFrame.maxX - panelWidth)
        // The enlarged title and its frost can draw below the row. Keep this canvas
        // separate from the content rectangle used for hover and drop targets.
        let bottomPadding = min(drawingPadding, max(0, content.minY - availableFrame.minY))
        return (content, CGRect(x: panelX, y: content.minY - bottomPadding,
                                width: panelWidth, height: height + bottomPadding))
    }

    static func notchBarSize(count: Int, appSpacing: CGFloat, availableFrame: CGRect,
                             groupedWidth: CGFloat? = nil, itemHeight: CGFloat = rowHeight) -> CGSize {
        let itemCount = max(1, count)
        let idealWidth = max(width, groupedWidth ?? (CGFloat(itemCount) * notchItemWidth
            + CGFloat(max(0, itemCount - 1)) * appSpacing)) + notchBarPadding * 2
        let maximumWidth = min(availableFrame.width,
            max(width + notchBarPadding * 2, availableFrame.width * notchBarMaximumScreenFraction))
        return CGSize(width: min(idealWidth, maximumWidth),
                      height: min(itemHeight + notchBarPadding * 2, availableFrame.height))
    }

    static func acceptsSidebarPointer(at point: CGPoint, sidebar: CGRect, menu: CGRect?) -> Bool {
        sidebar.contains(point) && !(menu?.contains(point) ?? false)
    }

    // Window lists sit immediately under the icon; desktop menus stay below the bar.
    static func notchMenuFrame(size: CGSize, icon: CGRect, bar: CGRect, screen: CGRect,
                               belowIcon: Bool = false) -> CGRect {
        let width = min(size.width, screen.width)
        let top = min(belowIcon ? icon.minY : bar.minY, screen.maxY)
        let height = min(size.height, max(0, top - screen.minY))
        let offset = belowIcon ? notchWindowMenuOffset : 0
        return CGRect(x: min(max(icon.midX - width / 2 + offset, screen.minX), screen.maxX - width),
                      y: top - height, width: width, height: height)
    }

    static func notchMenuBridge(menu: CGRect, anchor: CGRect) -> CGRect {
        guard menu.maxY <= anchor.minY else { return .zero }
        let left = max(menu.minX, anchor.minX)
        let right = min(menu.maxX, anchor.maxX)
        return CGRect(x: left, y: menu.maxY, width: max(0, right - left), height: anchor.minY - menu.maxY)
    }

    static func dragScrollDelta(at point: CGPoint, frame: CGRect, horizontal: Bool,
                                 flipped: Bool) -> CGPoint {
        guard frame.contains(point) else { return .zero }
        if horizontal {
            if point.x < frame.minX + 22 { return CGPoint(x: -10, y: 0) }
            if point.x > frame.maxX - 22 { return CGPoint(x: 10, y: 0) }
        } else {
            if point.y > frame.maxY - 22 { return CGPoint(x: 0, y: flipped ? -10 : 10) }
            if point.y < frame.minY + 22 { return CGPoint(x: 0, y: flipped ? 10 : -10) }
        }
        return .zero
    }
}

//// Kept apart from SidebarSettings so layout changes never touch saved preferences.
//////////////////
