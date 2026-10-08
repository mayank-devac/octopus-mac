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
            let state = entry.windowStates[id.windowID]
            // Only the focused window of the frontmost app is on top. A window that is merely
            // on-screen may be covered, so minimising it would hide a window the user cannot see.
            // Anything else comes forward instead; the executor rechecks focus before minimising.
            let isFrontFocused = frontmostPID == entry.pid && entry.focusedID == id
            guard !entry.isHidden, state?.isMinimized != true, state?.isOnScreen != false,
                  isFrontFocused else { return .focus(id) }
            return .minimize(id, requireFocused: true)
        case .place: return nil // Placement is a drag, never a click.
        }
    }
}

enum SidebarSnapTarget: String, CaseIterable {
    case left, right, top, bottom, maximize

    var title: String {
        switch self {
        case .left: return "Left half"
        case .right: return "Right half"
        case .bottom: return "Bottom half"
        case .top: return "Top half"
        case .maximize: return "Maximise"
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
    var snap: SidebarSnapTarget? = nil
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
        // Corners are free movement; they must not fall through to either adjacent edge.
        if (nearLeft || nearRight) && (nearTop || nearBottom) { return nil }
        if nearLeft { return .left }
        if nearRight { return .right }
        if nearTop { return .top }
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
        case .top: return CGRect(x: area.minX, y: area.midY, width: area.width, height: halfHeight)
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
// Rectangle documents why the size-position-size sequence exists: macOS fits a size to the
// display the window is currently on, so moving across displays needs a second size write
// (clone/Rectangle/AccessibilityElement.swift `setFrame`). Those writes are asynchronous,
// so this writer also confirms each stage instead of trusting a single immediate read.
enum SidebarPlacementWriter {
    static let maximumSettlePolls = 8
    // The initial write plus up to two re-assertions of whatever the app has not applied.
    static let maximumAttempts = 3

    static func apply(_ request: SidebarPlacementRequest, canContinue: () -> Bool,
                      readFrame: () -> CGRect?, writePosition: (CGPoint) -> Bool,
                      writeSize: (CGSize) -> Bool,
                      repeatSizeAfterMove: Bool = true, acceptStableMismatch: Bool = true,
                      wait: () -> Void = { Thread.sleep(forTimeInterval: 0.025) }) -> SidebarPlacementResult {
        guard SidebarPlacementGeometry.isValid(request.frame),
              SidebarPlacementGeometry.isValid(request.workArea) else { return .failed("Invalid window placement.") }
        guard canContinue() else { return .cancelled }

        func isOnTargetDisplay(_ frame: CGRect) -> Bool {
            request.workArea.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        func originMatches(_ frame: CGRect) -> Bool {
            abs(frame.minX - request.frame.minX) <= 2 && abs(frame.minY - request.frame.minY) <= 2
        }
        func sizeMatches(_ frame: CGRect) -> Bool {
            abs(frame.width - request.frame.width) <= 2 && abs(frame.height - request.frame.height) <= 2
        }
        func reached(_ frame: CGRect) -> Bool { originMatches(frame) && (!request.resize || sizeMatches(frame)) }

        // Poll until the frame satisfies `done`, or stops changing while still reachable.
        // An out-of-bounds frame may be the app's old size at the new position, so keep
        // waiting (bounded) before treating it as a limit that needs correcting.
        func settledFrame(until done: (CGRect) -> Bool, unreadable: String) -> SidebarPlacementResult {
            var previous: CGRect?
            for poll in 0..<maximumSettlePolls {
                guard canContinue() else { return .cancelled }
                guard let frame = readFrame(), SidebarPlacementGeometry.isValid(frame) else {
                    return .failed(unreadable)
                }
                let isReachable = SidebarPlacementGeometry.constrained(frame, to: request.workArea).origin == frame.origin
                if done(frame) || (acceptStableMismatch && isReachable && frame == previous)
                    || poll == maximumSettlePolls - 1 { return .placed(frame, adjusted: false) }
                previous = frame
                wait()
            }
            return .failed(unreadable)
        }

        // A window on another display would visibly shrink there and then jump across if
        // resized first. Land on the target display and wait for macOS to register it, so
        // the size writes are fitted to, and animate on, the display the window ends on.
        if request.resize, repeatSizeAfterMove, let current = readFrame(), SidebarPlacementGeometry.isValid(current),
           !isOnTargetDisplay(current) {
            _ = writePosition(request.workArea.origin)
            let landed = settledFrame(until: isOnTargetDisplay, unreadable: "The app did not report the window's position.")
            if case .cancelled = landed { return .cancelled }
        }

        var writeFailed = false
        var sizeWritable = request.resize
        func writeRequestedSize() {
            guard sizeWritable else { return }
            if !writeSize(request.frame.size) { sizeWritable = false; writeFailed = true }
        }
        writeRequestedSize()
        guard canContinue() else { return .cancelled }
        guard writePosition(request.frame.origin) else { return .failed("The app could not move this window; its size may have changed.") }
        guard canContinue() else { return .cancelled }
        if repeatSizeAfterMove { writeRequestedSize() }

        var actual: CGRect
        switch settledFrame(until: reached, unreadable: "The app did not report the window's final position.") {
        case .placed(let frame, _): actual = frame
        case let other: return other
        }

        // The app may drop a write made while its window was changing display or animating
        // (typically the last size write), leaving the old size at the new position. Ask again
        // before treating the result as an app limit; never move the window to compensate.
        var attempt = 1
        while attempt < maximumAttempts, !reached(actual) {
            let needsSize = sizeWritable && !sizeMatches(actual)
            let needsPosition = !originMatches(actual)
            guard needsSize || needsPosition, canContinue() else { break }
            if needsSize { writeRequestedSize() }
            if needsPosition, !writePosition(request.frame.origin) { break }
            if repeatSizeAfterMove, needsPosition, needsSize, canContinue() { writeRequestedSize() }
            switch settledFrame(until: reached, unreadable: "The app did not report the window's final position.") {
            case .placed(let frame, _): actual = frame
            case let other: return other
            }
            attempt += 1
        }

        let reachable = SidebarPlacementGeometry.constrained(actual, to: request.workArea)
        if reachable.origin != actual.origin {
            guard canContinue() else { return .cancelled }
            guard writePosition(reachable.origin) else {
                return .failed("The app limited placement; the window may extend beyond the display.")
            }
            switch settledFrame(until: { _ in true }, unreadable: "The app limited placement; the window may extend beyond the display.") {
            case .placed(let frame, _): actual = frame
            case let other: return other
            }
        }
        return .placed(actual, adjusted: writeFailed || !SidebarPlacementGeometry.matches(actual, request.frame))
    }
}
