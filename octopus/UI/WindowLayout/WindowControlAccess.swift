import AppKit

// Create the deadline before queueing work so waiting behind another AX operation uses the same time budget.
struct WindowControlBudget {
    let deadline: TimeInterval
    let canContinue: () -> Bool
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var isCurrent: Bool { canContinue() && clock() < deadline && AXIsProcessTrusted() }
}

struct WindowControlHandle {
    let id: WindowLayoutIdentity
    let element: AXUIElement
    let application: NSRunningApplication
    let isFullScreen: Bool
}

enum WindowControlResolution {
    case resolved(WindowControlHandle)
    case excluded
    case failed(String)
}

enum WindowControlRead {
    case window(WindowLayoutWindow)
    case excluded
    case failed(String)

    var window: WindowLayoutWindow? { if case .window(let window) = self { return window }; return nil }
}

enum WindowFrameWritePolicy { case crossDisplayPlacement, sameDisplayAdjustment }

// Queue ownership and handle generations stay with the reader; native layout rules have one boundary.
final class WindowControlAccess: @unchecked Sendable {
    let queue: DispatchQueue
    private let spaces: SidebarSpaceReader
    private let resolve: (SidebarWindowID, WindowControlBudget) -> WindowControlResolution

    init(queue: DispatchQueue, spaces: SidebarSpaceReader,
         resolve: @escaping (SidebarWindowID, WindowControlBudget) -> WindowControlResolution) {
        self.queue = queue
        self.spaces = spaces
        self.resolve = resolve
    }

    func scopeIsVisible(_ scope: WindowLayoutScope, displays: [WindowLayoutDisplay]) -> Bool {
        displays.contains { $0.id == scope.displayID } && spaces.visibleDesktopIDs().contains(scope.spaceID)
    }

    // Pair focus reuses the existing exact-window request; it never raises before that request.
    @MainActor func focusConfirmed(_ window: WindowLayoutWindow, token: WindowLayoutBatchToken,
                                   completion: @escaping () -> Void) {
        guard !token.isCancelled, let app = NSRunningApplication(processIdentifier: window.id.window.pid), !app.isTerminated else {
            completion(); return
        }
        let accepted = SidebarFocusActivation.request(canContinue: { !token.isCancelled && !app.isTerminated },
            yieldActivation: { NSApp.yieldActivation(to: app) }, activate: {
                SidebarFocusActivation.activate(target: window.id.window,
                    focusWindow: { SidebarWindowFocusRequest($0.pid, $0.windowID) }, activateApp: { app.activate(options: $0) })
            })
        guard accepted else { completion(); return }
        let displays = WindowLayoutDisplay.connected()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        queue.async { [weak self] in
            defer { DispatchQueue.main.async(execute: completion) }
            let budget = WindowControlBudget(deadline: deadline, canContinue: { !token.isCancelled })
            guard let self, !token.isCancelled,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let current = self.read(window.id.window, displays: displays, budget: budget, expected: window).window,
                  current.eligible, current.scope == window.scope,
                  SidebarPlacementGeometry.matches(current.frame, window.frame),
                  case .resolved(let handle) = self.resolve(window.id.window, budget),
                  handle.id == window.id, budget.isCurrent else { return }
            _ = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
        }
    }

    func read(_ id: SidebarWindowID, displays: [WindowLayoutDisplay], budget: WindowControlBudget,
              expected: WindowLayoutWindow? = nil, recency: UInt64 = 0, stackOrder: Int = Int.max) -> WindowControlRead {
        dispatchPrecondition(condition: .onQueue(queue))
        guard budget.isCurrent else { return .failed("Window control was cancelled or timed out.") }
        let handle: WindowControlHandle
        switch resolve(id, budget) {
        case .resolved(let value): handle = value
        case .excluded: return .excluded
        case .failed(let reason): return .failed(reason)
        }
        guard expected == nil || expected?.id == handle.id,
              !handle.application.isTerminated, handle.application.processIdentifier == id.pid,
              let owner = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id.windowID) as? [[String: Any]])?.first,
              (owner[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id.windowID,
              (owner[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == id.pid else {
            return .failed("This window is no longer available.")
        }
        guard (owner[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return .excluded }
        guard (owner[kCGWindowIsOnscreen as String] as? Bool) == true else { return .excluded }
        AXUIElementSetMessagingTimeout(handle.element, Float(min(0.2, max(0.001, budget.deadline - budget.clock()))))
        let attributes = [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute,
                          "AXFullScreen", "AXModal", "AXSheets", kAXRoleAttribute, kAXSubroleAttribute]
        guard let values = readAttributes(attributes, element: handle.element, budget: budget),
              let position = values[0].object, let size = values[1].object,
              let frame = AXUIElement.decodeWindowFrame(position: position, size: size),
              let minimized = values[2].optionalBool, let fullScreen = values[3].optionalBool,
              let modal = values[4].optionalBool,
              let sheets = (values[5].object as? [AXUIElement]) ?? (values[5].optionalAbsence ? [] : nil),
              let role = values[6].object as? String else {
            return .failed("The app did not report this window's current state.")
        }
        let subrole = values[7].object as? String
        guard subrole != nil || values[7].optionalAbsence else { return .failed("The app did not report this window's type.") }
        guard SidebarWindowPolicy.isTopLevelWindow(role: role, subrole: subrole) else { return .excluded }
        guard budget.isCurrent else { return .failed("Window control was cancelled or timed out.") }
        let memberships = spaces.read(windowIDs: [id.windowID])[id.windowID] ?? []
        guard memberships.count == 1, let desktop = memberships.first, desktop.number != nil,
              spaces.visibleDesktopIDs().contains(desktop.id) else { return .excluded }
        let physical = displays.max { a, b in Self.overlap(a.frame, frame) < Self.overlap(b.frame, frame) }
        guard let physical, Self.overlap(physical.frame, frame) > 0 else { return .failed("The window's display could not be verified.") }
        let minimum: CGSize
        let canMove: Bool, canResize: Bool
        // Reuse operation metadata, while the frame, visibility, modal state and Desktop membership stay live.
        if let expected {
            minimum = expected.minimum
            canMove = expected.canMove
            canResize = expected.canResize
        } else {
            guard let value = readMinimum(handle.element, budget: budget), budget.isCurrent else {
                return .failed("The app's window size limits could not be read.")
            }
            minimum = value
            canMove = settable(handle.element, attribute: kAXPositionAttribute, budget: budget)
            canResize = settable(handle.element, attribute: kAXSizeAttribute, budget: budget)
        }
        guard budget.isCurrent else { return .failed("Window control was cancelled or timed out.") }
        return .window(WindowLayoutWindow(id: handle.id,
            scope: WindowLayoutScope(displayID: physical.id, spaceID: desktop.id), frame: frame, minimum: minimum,
            canMove: canMove, canResize: canResize, hidden: handle.application.isHidden, minimized: minimized,
            blocked: fullScreen || handle.isFullScreen || modal || !sheets.isEmpty, recency: recency, stackOrder: stackOrder))
    }

    func write(_ expected: WindowLayoutWindow, frame: CGRect, workArea: CGRect,
               destination: WindowLayoutScope, displays: [WindowLayoutDisplay], budget: WindowControlBudget,
               policy: WindowFrameWritePolicy) -> SidebarPlacementResult {
        dispatchPrecondition(condition: .onQueue(queue))
        guard budget.isCurrent, scopeIsVisible(destination, displays: displays),
              let current = read(expected.id.window, displays: displays, budget: budget, expected: expected).window,
              current.scope == expected.scope, current.eligible,
              SidebarPlacementGeometry.matches(current.frame, expected.frame) else { return .cancelled }
        guard case .resolved(let handle) = resolve(expected.id.window, budget), handle.id == expected.id else { return .cancelled }
        // Recheck immediately before each setter; an app can close, show a sheet or change Desktop mid-write.
        func permitted() -> Bool {
            guard budget.isCurrent, scopeIsVisible(destination, displays: displays),
                  let live = read(expected.id.window, displays: displays, budget: budget, expected: expected).window,
                  live.eligible else { return false }
            if policy == .sameDisplayAdjustment { return live.scope == destination }
            // Native membership/frame can settle separately during the explicitly requested visible-display move.
            return [expected.scope.displayID, destination.displayID].contains(live.scope.displayID)
                && [expected.scope.spaceID, destination.spaceID].contains(live.scope.spaceID)
        }
        let request = SidebarPlacementRequest(frame: frame, workArea: workArea, resize: true, desktopGeneration: 0)
        return Self.withoutEnhancedUserInterface(pid: expected.id.window.pid) {
            SidebarPlacementWriter.apply(request, canContinue: { budget.isCurrent },
                readFrame: { budget.isCurrent ? handle.element.getWindowFrame() : nil },
                writePosition: { position in
                    guard permitted() else { return false }
                    var position = position
                    guard let value = AXValueCreate(.cgPoint, &position) else { return false }
                    return AXUIElementSetAttributeValue(handle.element, kAXPositionAttribute as CFString, value) == .success
                }, writeSize: { size in
                    guard permitted() else { return false }
                    var size = size
                    guard let value = AXValueCreate(.cgSize, &size) else { return false }
                    return AXUIElementSetAttributeValue(handle.element, kAXSizeAttribute as CFString, value) == .success
                }, repeatSizeAfterMove: policy == .crossDisplayPlacement, acceptStableMismatch: false)
        }
    }

    private func readAttributes(_ attributes: [String], element: AXUIElement,
                                budget: WindowControlBudget) -> [WindowAXAttributeValue]? {
        guard budget.isCurrent else { return nil }
        var array: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &array)
        if result == .success, let values = array as? [AnyObject], values.count == attributes.count {
            let slots = values.map { WindowAXAttributeValue($0) }
            if [0, 1, 6].contains(where: { if case .failed = slots[$0] { return true }; return false }) { return slots }
            // Optional unsupported values have legitimate defaults; required geometry/role is resolved narrowly.
            if ![0, 1, 6].contains(where: { slots[$0].needsIndividualFallback }) { return slots }
        } else if result != .notImplemented && result != .attributeUnsupported { return nil }
        var values: [WindowAXAttributeValue] = []
        for attribute in attributes {
            guard budget.isCurrent else { return nil }
            var object: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &object)
            if error == .success { values.append(WindowAXAttributeValue(object)) }
            else if error == .attributeUnsupported || error == .notImplemented { values.append(.unsupported) }
            else if error == .noValue { values.append(.absent) }
            else { values.append(.failed(error)) }
        }
        return values
    }

    private func readMinimum(_ element: AXUIElement, budget: WindowControlBudget) -> CGSize? {
        for attribute in ["AXMinSize", "AXMinimumSize"] {
            guard budget.isCurrent else { return nil }
            var object: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &object)
            if error == .attributeUnsupported || error == .notImplemented || error == .noValue { continue }
            guard error == .success else { return nil }
            let slot = WindowAXAttributeValue(object)
            if slot.optionalAbsence { continue }
            guard let value = slot.object, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            let ax = unsafeBitCast(value, to: AXValue.self)
            var size = CGSize.zero
            guard AXValueGetType(ax) == .cgSize, AXValueGetValue(ax, .cgSize, &size),
                  size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0 else { return nil }
            return size
        }
        return .zero
    }

    private func settable(_ element: AXUIElement, attribute: String, budget: WindowControlBudget) -> Bool {
        guard budget.isCurrent else { return false }
        var value = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &value) == .success && value.boolValue
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    // Suspend AX frame animations while writing, then restore the app's original setting.
    // This is the existing Rectangle-inspired placement policy (clone/Rectangle/AccessibilityElement.swift).
    static func withoutEnhancedUserInterface<T>(pid: pid_t, _ body: () -> T) -> T {
        let attribute = "AXEnhancedUserInterface" as CFString
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        let enabled = AXUIElementCopyAttributeValue(app, attribute, &value) == .success && (value as? Bool) == true
        if enabled { _ = AXUIElementSetAttributeValue(app, attribute, kCFBooleanFalse) }
        defer { if enabled { _ = AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue) } }
        return body()
    }
}
