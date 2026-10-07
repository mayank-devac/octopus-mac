import AppKit

enum SidebarIconDragPolicy {
    static func target(for entry: SidebarEntry) -> SidebarWindowID? {
        // Match the window title shown under the icon; never substitute another window.
        guard let id = entry.preferredID, id.pid == entry.pid,
              entry.windows.contains(where: { $0.cgWindowID == id.windowID }) else { return nil }
        return id
    }
}

enum SidebarIconMousePolicy {
    static func action(_ shortcutAction: MouseShortcutAction, for entry: SidebarEntry,
                       frontmostPID: pid_t?, target: SidebarWindowID?) -> SidebarWindowAction? {
        switch shortcutAction {
        case .hide:
            return SidebarIconClickPolicy.action(for: entry, frontmostPID: frontmostPID, setting: .hide)
        case .minimize:
            guard let id = target, id.pid == entry.pid,
                  entry.windows.contains(where: { $0.cgWindowID == id.windowID }) else { return nil }
            let minimized = entry.windowStates[id.windowID]?.isMinimized == true
            return entry.isHidden || minimized ? .focus(id) : .minimize(id, requireFocused: false)
        case .place: return nil // Placement is a drag, never a click.
        }
    }
}

enum SidebarSnapTarget: String, CaseIterable {
    case left, right, bottom, maximize, topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .left: return "Left half"
        case .right: return "Right half"
        case .bottom: return "Bottom half"
        case .maximize: return "Maximise"
        case .topLeft: return "Top-left quarter"
        case .topRight: return "Top-right quarter"
        case .bottomLeft: return "Bottom-left quarter"
        case .bottomRight: return "Bottom-right quarter"
        }
    }
}

struct SidebarPlacementTarget {
    let id: SidebarWindowID
    let frame: CGRect // Accessibility coordinates, in points.
    let canResize: Bool
    let isMinimized: Bool
    let desktopGeneration: Int
}

enum SidebarPlacementEligibility {
    static func allows(fullScreen: Bool, modal: Bool, hasSheets: Bool, canMove: Bool,
                       windowDesktops: Set<UInt64>, visibleDesktops: Set<UInt64>) -> Bool {
        !fullScreen && !modal && !hasSheets && canMove
            && !windowDesktops.isDisjoint(with: visibleDesktops)
    }
}

struct SidebarPlacementRequest: Equatable {
    let frame: CGRect
    let workArea: CGRect
    let resize: Bool
    let desktopGeneration: Int
}

enum SidebarPlacementResult: Equatable {
    case placed(CGRect, adjusted: Bool)
    case failed(String)
    case cancelled

    var message: String? {
        switch self {
        case .placed(_, let adjusted): return adjusted ? "This app limited the window size or position." : nil
        case .failed(let message): return message
        case .cancelled: return nil
        }
    }
}

enum SidebarPlacementGeometry {
    static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    // AX starts at the primary display's top-left; AppKit starts at its bottom-left.
    // Use the same reference for every display, including negative screen origins.
    static func flip(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func snap(at point: CGPoint, screen: CGRect, distance: Double = SidebarSettings.defaultSnapDistance) -> SidebarSnapTarget? {
        guard screen.contains(point) else { return nil }
        let left = point.x - screen.minX
        let right = screen.maxX - point.x
        let bottom = point.y - screen.minY
        let top = screen.maxY - point.y
        // Let people drop near the side rather than having to hit the screen border.
        // Cap each band on small displays so opposite zones leave a free-move centre.
        let reach = CGFloat(SidebarSettings.normalizedSnapDistance(distance))
        let horizontalReach = min(reach, screen.width / 4)
        let verticalReach = min(reach, screen.height / 4)
        let nearLeft = left <= horizontalReach
        let nearRight = right <= horizontalReach
        let nearTop = top <= verticalReach
        let nearBottom = bottom <= verticalReach
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearLeft { return .left }
        if nearRight { return .right }
        if nearTop { return .maximize }
        if nearBottom { return .bottom }
        return nil
    }

    static func frame(for target: SidebarSnapTarget, in area: CGRect) -> CGRect {
        let halfWidth = area.width / 2
        let halfHeight = area.height / 2
        switch target {
        case .maximize: return area
        case .left: return CGRect(x: area.minX, y: area.minY, width: halfWidth, height: area.height)
        case .right: return CGRect(x: area.midX, y: area.minY, width: halfWidth, height: area.height)
        case .bottom: return CGRect(x: area.minX, y: area.minY, width: area.width, height: halfHeight)
        case .topLeft: return CGRect(x: area.minX, y: area.midY, width: halfWidth, height: halfHeight)
        case .topRight: return CGRect(x: area.midX, y: area.midY, width: halfWidth, height: halfHeight)
        case .bottomLeft: return CGRect(x: area.minX, y: area.minY, width: halfWidth, height: halfHeight)
        case .bottomRight: return CGRect(x: area.midX, y: area.minY, width: halfWidth, height: halfHeight)
        }
    }

    static func freeFrame(at point: CGPoint, size: CGSize, in area: CGRect) -> CGRect {
        let x = min(max(point.x - size.width / 2, area.minX), max(area.minX, area.maxX - size.width))
        let topAlignedY = area.maxY - size.height
        let y = min(max(point.y - size.height, min(area.minY, topAlignedY)), topAlignedY)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func constrained(_ frame: CGRect, to area: CGRect) -> CGRect {
        // Oversized windows retain their size; keep the title bar reachable.
        CGRect(x: min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width)),
               y: min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height)),
               width: frame.width, height: frame.height)
    }

    static func matches(_ actual: CGRect, _ requested: CGRect) -> Bool {
        abs(actual.minX - requested.minX) <= 2 && abs(actual.minY - requested.minY) <= 2
            && abs(actual.width - requested.width) <= 2 && abs(actual.height - requested.height) <= 2
    }
}

// Keep the operation order and failure handling testable without controlling another app.
// The size-position-size sequence is informed by Rectangle; see clone/Rectangle/manifest.json.
enum SidebarPlacementWriter {
    static func apply(_ request: SidebarPlacementRequest, canContinue: () -> Bool,
                      readFrame: () -> CGRect?, writePosition: (CGPoint) -> Bool,
                      writeSize: (CGSize) -> Bool) -> SidebarPlacementResult {
        guard SidebarPlacementGeometry.isValid(request.frame),
              SidebarPlacementGeometry.isValid(request.workArea) else { return .failed("Invalid window placement.") }
        guard canContinue() else { return .cancelled }
        var writeFailed = false
        if request.resize { writeFailed = !writeSize(request.frame.size) }
        guard canContinue() else { return .cancelled }
        guard writePosition(request.frame.origin) else { return .failed("The app could not move this window; its size may have changed.") }
        guard canContinue() else { return .cancelled }
        if request.resize { writeFailed = !writeSize(request.frame.size) || writeFailed }
        guard canContinue() else { return .cancelled }
        guard var actual = readFrame(), SidebarPlacementGeometry.isValid(actual) else {
            return .failed("The app did not report the window's final position.")
        }
        let reachable = SidebarPlacementGeometry.constrained(actual, to: request.workArea)
        if reachable.origin != actual.origin {
            guard canContinue() else { return .cancelled }
            guard writePosition(reachable.origin), let corrected = readFrame(),
                  SidebarPlacementGeometry.isValid(corrected) else {
                return .failed("The app limited placement; the window may extend beyond the display.")
            }
            actual = corrected
        }
        return .placed(actual, adjusted: writeFailed || !SidebarPlacementGeometry.matches(actual, request.frame))
    }
}
