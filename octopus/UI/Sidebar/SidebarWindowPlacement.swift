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
            // The default left click is bound to minimise/restore. With no window,
            // route it to app activation so the inventory can validate reopening.
            // A captured stale target or another Desktop's window must not reopen.
            if target == nil, entry.preferredID == nil, entry.windows.isEmpty, !entry.hasOtherWindows {
                return .activateApp(entry.pid)
            }
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
    case topLeft, topRight, bottomLeft, bottomRight

    var isCorner: Bool { self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight }
    var isRightCorner: Bool { self == .topRight || self == .bottomRight }
    var isBottomCorner: Bool { self == .bottomLeft || self == .bottomRight }

    var title: String {
        switch self {
        case .left: return "Left half"
        case .right: return "Right half"
        case .bottom: return "Bottom half"
        case .top: return "Top half"
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
    let isHidden: Bool
    let desktopGeneration: Int
}

enum SidebarMaximizeDisposition: Equatable {
    case noOp, place, focus
}

enum SidebarMaximizePolicy {
    static func disposition(target: SidebarPlacementTarget?, workArea: CGRect?,
                            displayIsFullScreen: Bool) -> SidebarMaximizeDisposition {
        guard let target, let workArea, !displayIsFullScreen,
              SidebarPlacementGeometry.isValid(workArea) else { return .focus }
        if SidebarPlacementGeometry.isAlreadyMaximized(target.frame, in: workArea,
            isMinimized: target.isMinimized, isHidden: target.isHidden) { return .noOp }
        return target.canResize ? .place : .focus
    }
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
    var crossesDisplay = false
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

    static func snap(at point: CGPoint, screen: CGRect, distance: Double = SidebarSettings.defaultSnapDistance,
                     corners: Bool = false) -> SidebarSnapTarget? {
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
        // A corner without the chord remains free movement rather than becoming an adjacent half.
        if (nearLeft || nearRight) && (nearTop || nearBottom) {
            guard corners else { return nil }
            if nearTop { return nearLeft ? .topLeft : .topRight }
            return nearLeft ? .bottomLeft : .bottomRight
        }
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
        case .topLeft: return CGRect(x: area.minX, y: area.midY, width: halfWidth, height: halfHeight)
        case .topRight: return CGRect(x: area.midX, y: area.midY, width: halfWidth, height: halfHeight)
        case .bottomLeft: return CGRect(x: area.minX, y: area.minY, width: halfWidth, height: halfHeight)
        case .bottomRight: return CGRect(x: area.midX, y: area.minY, width: halfWidth, height: halfHeight)
        }
    }

    // AX grows downward. Preserve the chosen corner even when the app enlarges the quarter.
    static func cornerFrame(_ snap: SidebarSnapTarget, size: CGSize, inAX area: CGRect) -> CGRect {
        CGRect(x: snap.isRightCorner ? area.maxX - size.width : area.minX,
               y: snap.isBottomCorner ? area.maxY - size.height : area.minY,
               width: size.width, height: size.height)
    }

    static func sourceDisplay(for frame: CGRect, displays: [CGRect]) -> CGRect? {
        guard isValid(frame) else { return nil }
        func overlap(_ display: CGRect) -> CGFloat {
            let intersection = display.intersection(frame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        return displays.filter { overlap($0) > 0 }.max {
            overlap($0) < overlap($1)
        }
    }

    struct Decision: Equatable {
        let frame: CGRect // AppKit coordinates, used directly by the preview.
        let snap: SidebarSnapTarget?
        let resize: Bool
    }

    // Both preview and commit resolve here. Desktop-menu and icon-pair drops bypass this path.
    static func resolve(at point: CGPoint, screen: CGRect, workArea: CGRect, originalSize: CGSize,
                        sourceDisplay: CGRect?, canResize: Bool, distance: Double,
                        cornersEnabled: Bool,
                        moveSize: VisibleDisplayMoveSize) -> Decision? {
        let snap = snap(at: point, screen: screen, distance: distance, corners: cornersEnabled)
        if let snap {
            guard canResize else { return nil }
            return Decision(frame: frame(for: snap, in: workArea), snap: snap, resize: true)
        }
        let crossDisplay = canResize && sourceDisplay != nil && sourceDisplay != screen
        let fillDisplay = crossDisplay && moveSize == .fullScreen
        return Decision(frame: fillDisplay ? workArea : freeFrame(at: point, size: originalSize, in: workArea),
                        snap: nil, resize: crossDisplay)
    }

    static func freeFrame(at point: CGPoint, size: CGSize, in area: CGRect) -> CGRect {
        let x = min(max(point.x - size.width / 2, area.minX), max(area.minX, area.maxX - size.width))
        let topAlignedY = area.maxY - size.height
        let y = min(max(point.y - size.height, min(area.minY, topAlignedY)), topAlignedY)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // Use the size accepted by the app, keeping the selected outside edge fixed.
    // AX coordinates grow downwards, so bottom alignment subtracts the accepted height.
    static func snapFrame(_ snap: SidebarSnapTarget, size: CGSize, inAX area: CGRect) -> CGRect {
        if snap.isCorner { return cornerFrame(snap, size: size, inAX: area) }
        let x = snap == .right ? area.maxX - size.width : area.minX
        let y = snap == .bottom ? area.maxY - size.height : area.minY
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
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

    static func isAlreadyMaximized(_ frame: CGRect, in workArea: CGRect,
                                   isMinimized: Bool, isHidden: Bool) -> Bool {
        !isMinimized && !isHidden && isValid(frame) && isValid(workArea) && matches(frame, workArea)
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
                      acceptStableMismatch: Bool = true,
                      singleAttempt: Bool = false,
                      hasLanded: ((CGRect) -> Bool)? = nil,
                      wait: () -> Void = { Thread.sleep(forTimeInterval: 0.025) }) -> SidebarPlacementResult {
        if singleAttempt {
            return applyOnce(request, canContinue: canContinue, readFrame: readFrame,
                writePosition: writePosition, writeSize: writeSize, hasLanded: hasLanded, wait: wait)
        }
        let repeatsAfterMove = request.crossesDisplay
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
        if request.resize, repeatsAfterMove, let current = readFrame(), SidebarPlacementGeometry.isValid(current),
           !isOnTargetDisplay(current) {
            guard writePosition(request.workArea.origin) else { return .failed("The app could not move this window to the display.") }
            let landed = settledFrame(until: isOnTargetDisplay, unreadable: "The app did not report the window's position.")
            guard case .placed = landed else { return landed }
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
        if repeatsAfterMove { writeRequestedSize() }

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
            if needsPosition, !writePosition(request.frame.origin) { writeFailed = true; break }
            if repeatsAfterMove, needsPosition, needsSize, canContinue() { writeRequestedSize() }
            switch settledFrame(until: reached, unreadable: "The app did not report the window's final position.") {
            case .placed(let frame, _): actual = frame
            case let other: return other
            }
            attempt += 1
        }

        guard canContinue() else { return .cancelled }
        let reachable: CGRect
        if let snap = request.snap, snap != .maximize {
            reachable = SidebarPlacementGeometry.snapFrame(snap, size: actual.size, inAX: request.workArea)
            guard request.workArea.contains(reachable) else {
                return .failed("This app's minimum size cannot fit on the display; the window may have moved.")
            }
        } else { reachable = SidebarPlacementGeometry.constrained(actual, to: request.workArea) }
        if reachable.origin != actual.origin {
            guard canContinue() else { return .cancelled }
            guard writePosition(reachable.origin) else {
                return .failed("The app limited placement; the window may extend beyond the display.")
            }
            switch settledFrame(until: { abs($0.minX - reachable.minX) <= 2 && abs($0.minY - reachable.minY) <= 2 },
                                unreadable: "The app limited placement; the window may extend beyond the display.") {
            case .placed(let frame, _): actual = frame
            case let other: return other
            }
        }
        guard canContinue() else { return .cancelled }
        guard !writeFailed else { return .failed("The app rejected the window's size or position; it may have moved.") }
        if let snap = request.snap, snap != .maximize,
           !SidebarPlacementGeometry.matches(actual, SidebarPlacementGeometry.snapFrame(snap, size: actual.size, inAX: request.workArea)) {
            return .failed("The app could not keep the window at the chosen snap edge; it may have moved.")
        }
        return .placed(actual, adjusted: !SidebarPlacementGeometry.matches(actual, request.frame))
    }

    // A snap gets one size request. Reads can wait for a delayed app; they never reassert a write.
    private static func applyOnce(_ request: SidebarPlacementRequest, canContinue: () -> Bool,
                                  readFrame: () -> CGRect?, writePosition: (CGPoint) -> Bool,
                                  writeSize: (CGSize) -> Bool, hasLanded: ((CGRect) -> Bool)?,
                                  wait: () -> Void) -> SidebarPlacementResult {
        guard canContinue() else { return .cancelled }
        guard SidebarPlacementGeometry.isValid(request.frame), SidebarPlacementGeometry.isValid(request.workArea),
              let starting = readFrame(), SidebarPlacementGeometry.isValid(starting) else {
            return .failed("The window's starting position could not be confirmed.")
        }
        guard canContinue() else { return .cancelled }
        if SidebarPlacementGeometry.matches(starting, request.frame) { return .placed(starting, adjusted: false) }
        func landed(_ frame: CGRect) -> Bool {
            hasLanded?(frame) ?? request.workArea.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        if request.crossesDisplay && !landed(starting) {
            guard canContinue() else { return .cancelled }
            guard writePosition(request.workArea.origin) else { return .failed("The app could not move to this display.") }
            var arrived = false
            for _ in 0..<maximumSettlePolls {
                guard canContinue() else { return .cancelled }
                guard let frame = readFrame(), SidebarPlacementGeometry.isValid(frame) else {
                    return .failed("The window's destination could not be confirmed.")
                }
                if landed(frame) { arrived = true; break }
                wait()
            }
            guard arrived else { return .failed("The window did not confirm arrival; no size request was sent.") }
        }
        guard canContinue() else { return .cancelled }
        guard let before = readFrame(), SidebarPlacementGeometry.isValid(before) else {
            return .failed("The window's position could not be confirmed.")
        }
        let needsSize = request.resize && (abs(before.width - request.frame.width) > 2 || abs(before.height - request.frame.height) > 2)
        if needsSize {
            guard canContinue() else { return .cancelled }
            guard writeSize(request.frame.size) else { return .failed("The app rejected the size request; achieved positions were kept.") }
        }
        if abs(before.minX - request.frame.minX) > 2 || abs(before.minY - request.frame.minY) > 2 {
            guard canContinue() else { return .cancelled }
            guard writePosition(request.frame.origin) else { return .failed("The app rejected the position; its size may have changed.") }
        }
        var previous: CGRect?
        var actual = before
        var stable = false
        for _ in 0..<maximumSettlePolls {
            guard canContinue() else { return .cancelled }
            guard let frame = readFrame(), SidebarPlacementGeometry.isValid(frame) else {
                return .failed("The app did not confirm its resulting position.")
            }
            actual = frame
            if SidebarPlacementGeometry.matches(frame, request.frame) {
                return canContinue() ? .placed(frame, adjusted: false) : .cancelled
            }
            stable = previous.map { SidebarPlacementGeometry.matches($0, frame) } ?? false
            previous = frame
            wait()
        }
        guard canContinue() else { return .cancelled }
        guard stable, !SidebarPlacementGeometry.matches(actual, before),
              !needsSize || abs(actual.width - before.width) > 2 || abs(actual.height - before.height) > 2,
              let fresh = readFrame(), SidebarPlacementGeometry.isValid(fresh),
              SidebarPlacementGeometry.matches(fresh, actual) else {
            return .failed("The size request remains unconfirmed; no retry was sent.")
        }
        let aligned = request.snap.map { SidebarPlacementGeometry.snapFrame($0, size: actual.size, inAX: request.workArea) } ?? actual
        let reachable = SidebarPlacementGeometry.constrained(aligned, to: request.workArea)
        if abs(actual.minX - reachable.minX) > 2 || abs(actual.minY - reachable.minY) > 2 {
            guard canContinue() else { return .cancelled }
            guard writePosition(reachable.origin) else { return .failed("The accepted size was kept, but edge alignment failed.") }
            var confirmed = false
            for _ in 0..<maximumSettlePolls {
                guard canContinue() else { return .cancelled }
                guard let frame = readFrame(), SidebarPlacementGeometry.isValid(frame) else { break }
                actual = frame
                if SidebarPlacementGeometry.matches(frame, reachable) { confirmed = true; break }
                wait()
            }
            guard confirmed else { return .failed("The accepted size was kept, but edge alignment is unconfirmed.") }
        }
        guard canContinue() else { return .cancelled }
        return .placed(actual, adjusted: !SidebarPlacementGeometry.matches(actual, request.frame))
    }
}
