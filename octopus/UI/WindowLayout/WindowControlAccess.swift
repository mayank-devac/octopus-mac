import AppKit
import OSLog
import os

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

enum WindowFrameWritePolicy { case crossDisplayPlacement, sameDisplayAdjustment, preparedSnap }

enum WindowTabPresence { case present, missing, separated, unknown }

// Queue ownership and handle generations stay with the reader; native layout rules have one boundary.
final class WindowControlAccess: @unchecked Sendable {
    let queue: DispatchQueue
    private let spaces: SidebarSpaceReader
    private let resolve: (SidebarWindowID, WindowControlBudget) -> WindowControlResolution
    private let logger = Logger(subsystem: "com.mayank.octopus", category: "WindowResizeDiagnostics")

    init(queue: DispatchQueue, spaces: SidebarSpaceReader,
         resolve: @escaping (SidebarWindowID, WindowControlBudget) -> WindowControlResolution) {
        self.queue = queue
        self.spaces = spaces
        self.resolve = resolve
    }

    func scopeIsVisible(_ scope: WindowLayoutScope, displays: [WindowLayoutDisplay]) -> Bool {
        displays.contains { $0.id == scope.displayID } && spaces.visibleDesktopIDs().contains(scope.spaceID)
    }

    func visibleScope(on displayID: String, budget: WindowControlBudget) -> WindowLayoutScope? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard budget.isCurrent, let desktop = spaces.visibleDesktop(on: displayID), budget.isCurrent else { return nil }
        return WindowLayoutScope(displayID: displayID, spaceID: desktop.id)
    }

    func focusedWindowID(pid: pid_t, budget: WindowControlBudget) -> SidebarWindowID? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard budget.isCurrent, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
              !app.isTerminated, !app.isHidden else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Float(min(0.2, max(0.001, budget.deadline - budget.clock()))))
        guard let focused: AXUIElement = element.getAttributeValue(.focusedWindow), budget.isCurrent else { return nil }
        AXUIElementSetMessagingTimeout(focused, Float(min(0.2, max(0.001, budget.deadline - budget.clock()))))
        guard let number = focused.getWindowID(), budget.isCurrent else { return nil }
        return SidebarWindowID(pid: pid, windowID: number)
    }

    // The shortcut moves an already focused window. Never activate its app again: the user
    // may have switched apps or windows while the native move was finishing.
    func raiseFocused(_ expected: WindowLayoutWindow, displays: [WindowLayoutDisplay],
                      budget: WindowControlBudget) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard budget.isCurrent,
              let current = read(expected.id.window, displays: displays, budget: budget, expected: expected).window,
              current.movable, current.scope == expected.scope,
              SidebarPlacementGeometry.matches(current.frame, expected.frame),
              case .resolved(let handle) = resolve(expected.id.window, budget), handle.id == expected.id,
              focusedWindowID(pid: expected.id.window.pid, budget: budget) == expected.id.window,
              budget.isCurrent else { return false }
        return AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString) == .success
            && focusedWindowID(pid: expected.id.window.pid, budget: budget) == expected.id.window
    }

    // Pair focus reuses the existing exact-window request; it never raises before that request.
    @MainActor func focusConfirmed(_ window: WindowLayoutWindow, token: WindowLayoutBatchToken,
                                   completion: @escaping () -> Void) {
        guard !token.isCancelled, let app = NSRunningApplication(processIdentifier: window.id.window.pid), !app.isTerminated else {
            completion(); return
        }
        let displays = WindowLayoutDisplay.connected()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let waiter = WindowForegroundActivationWaiter(targetPID: app.processIdentifier,
            initialPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            center: NSWorkspace.shared.notificationCenter,
            canContinue: { !token.isCancelled && !app.isTerminated },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier }) { [weak self] activated in
            guard activated, let self else { completion(); return }
            self.queue.async { [weak self] in
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
        // The existing sidebar path also raises only after didActivateApplication.
        // An accepted activate() request alone is not proof that the app is frontmost.
        waiter.start {
            SidebarFocusActivation.request(canContinue: { !token.isCancelled && !app.isTerminated },
                yieldActivation: { NSApp.yieldActivation(to: app) }, activate: {
                    return SidebarFocusActivation.activate(target: window.id.window,
                        focusWindow: { SidebarWindowFocusRequest($0.pid, $0.windowID) }, activateApp: { app.activate(options: $0) })
                })
        }
    }

    func tabIsInFront(_ window: SidebarWindowID, members: Set<SidebarWindowID>, budget: WindowControlBudget) -> Bool? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard budget.isCurrent,
              let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let ordered = records.compactMap { record -> SidebarWindowID? in
            guard (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let number = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return SidebarWindowID(pid: pid, windowID: number)
        }
        return Self.frontmostTab(in: ordered, members: members) == window
    }

    static func frontmostTab(in ordered: [SidebarWindowID], members: Set<SidebarWindowID>) -> SidebarWindowID? {
        ordered.first { members.contains($0) }
    }

    // Admit only the exact normal AX window on one visible Desktop; optional metadata absence is not a read error.
    func read(_ id: SidebarWindowID, displays: [WindowLayoutDisplay], budget: WindowControlBudget,
              expected: WindowLayoutWindow? = nil, recency: UInt64 = 0, stackOrder: Int = Int.max,
              forFocus: Bool = false) -> WindowControlRead {
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
        // A focus request may need to reveal a covered window. Its native identity,
        // normal role, ordinary visible Desktop and physical display are still verified below.
        guard forFocus || (owner[kCGWindowIsOnscreen as String] as? Bool) == true else { return .excluded }
        AXUIElementSetMessagingTimeout(handle.element, Float(min(0.2, max(0.001, budget.deadline - budget.clock()))))
        let attributes = [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute,
                          "AXFullScreen", "AXModal", "AXSheets", kAXRoleAttribute, kAXSubroleAttribute]
        guard let values = readAttributes(attributes, element: handle.element, budget: budget, requiredIndices: [0, 1, 6]),
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
        let minimumReported: Bool
        let canMove: Bool, canResize: Bool
        // Reuse operation metadata, while the frame, visibility, modal state and Desktop membership stay live.
        if let expected {
            minimum = expected.minimum
            minimumReported = expected.minimumReported
            canMove = expected.canMove
            canResize = expected.canResize
        } else {
            guard let value = readMinimum(handle.element, budget: budget), budget.isCurrent else {
                return .failed("The app's window size limits could not be read.")
            }
            minimum = value.size
            minimumReported = value.reported
            canMove = settable(handle.element, attribute: kAXPositionAttribute, budget: budget)
            canResize = settable(handle.element, attribute: kAXSizeAttribute, budget: budget)
        }
        guard budget.isCurrent else { return .failed("Window control was cancelled or timed out.") }
        return .window(WindowLayoutWindow(id: handle.id,
            scope: WindowLayoutScope(displayID: physical.id, spaceID: desktop.id), frame: frame,
            minimum: minimum, minimumReported: minimumReported,
            canMove: canMove, canResize: canResize, hidden: handle.application.isHidden, minimized: minimized,
            blocked: fullScreen || handle.isFullScreen || modal || !sheets.isEmpty, recency: recency, stackOrder: stackOrder))
    }

    // The caller supplies its last verified starting frame. Reject intervening movement before any setter.
    func write(_ expected: WindowLayoutWindow, frame: CGRect, workArea: CGRect,
               destination: WindowLayoutScope, displays: [WindowLayoutDisplay], budget: WindowControlBudget,
               policy: WindowFrameWritePolicy, resize: Bool = true,
               requireFocused: Bool = false, snap: SidebarSnapTarget? = nil,
               allowCovered: Bool = false) -> SidebarPlacementResult {
        dispatchPrecondition(condition: .onQueue(queue))
        guard budget.isCurrent, scopeIsVisible(destination, displays: displays),
              let current = read(expected.id.window, displays: displays, budget: budget,
                expected: expected, forFocus: allowCovered).window,
              current.scope == expected.scope, current.movable, (!resize || current.canResize),
              SidebarPlacementGeometry.matches(current.frame, expected.frame) else { return .cancelled }
        guard case .resolved(let handle) = resolve(expected.id.window, budget), handle.id == expected.id else { return .cancelled }
        // Recheck immediately before each setter; an app can close, show a sheet or change Desktop mid-write.
        func permitted() -> Bool {
            guard budget.isCurrent, scopeIsVisible(destination, displays: displays),
                  let live = read(expected.id.window, displays: displays, budget: budget,
                    expected: expected, forFocus: allowCovered).window,
                  live.movable, (!resize || live.canResize) else { return false }
            if requireFocused {
                guard focusedWindowID(pid: expected.id.window.pid, budget: budget) == expected.id.window,
                      visibleScope(on: expected.scope.displayID, budget: budget) == expected.scope,
                      visibleScope(on: destination.displayID, budget: budget) == destination else { return false }
            }
            if policy == .sameDisplayAdjustment || (policy == .preparedSnap && expected.scope == destination) {
                return live.scope == destination
            }
            // Native membership/frame can settle separately during the explicitly requested visible-display move.
            return [expected.scope.displayID, destination.displayID].contains(live.scope.displayID)
                && [expected.scope.spaceID, destination.spaceID].contains(live.scope.spaceID)
        }
        let request = SidebarPlacementRequest(frame: frame, workArea: workArea, resize: resize,
            desktopGeneration: 0, snap: snap,
            crossesDisplay: policy == .crossDisplayPlacement || (policy == .preparedSnap && expected.scope.displayID != destination.displayID))
        var writeResults: [String] = []
        var nativeFailure: AXError?
        var blocked = false
        // Both setters share failure bookkeeping so a refused command cannot be learned as an app size limit.
        func set(_ attribute: String, value: AXValue?, label: String) -> Bool {
            guard permitted() else { blocked = true; writeResults.append("\(label):blocked"); return false }
            guard let value else {
                nativeFailure = .illegalArgument
                writeResults.append("\(label):value-failed")
                return false
            }
            let error = AXUIElementSetAttributeValue(handle.element, attribute as CFString, value)
            writeResults.append("\(label):\(error.rawValue)")
            if error != .success { nativeFailure = error }
            return error == .success
        }
        let policyName = policy == .preparedSnap ? "single-snap" : (policy == .crossDisplayPlacement ? "cross-display" : "same-display")
        let startedAt = budget.clock()
        logger.debug("Resize start window=\(expected.id.window.windowID, privacy: .public) policy=\(policyName, privacy: .public) start=\(String(describing: current.frame), privacy: .public) requested=\(String(describing: frame), privacy: .public) minimum=\(String(describing: expected.minimum), privacy: .public) minimumReported=\(expected.minimumReported, privacy: .public)")
        var result = Self.withoutEnhancedUserInterface(pid: expected.id.window.pid) {
            SidebarPlacementWriter.apply(request, canContinue: { budget.isCurrent },
                readFrame: { budget.isCurrent ? handle.element.getWindowFrame() : nil },
                writePosition: { position in
                    var position = position
                    return set(kAXPositionAttribute, value: AXValueCreate(.cgPoint, &position), label: "position")
                }, writeSize: { size in
                    var size = size
                    return set(kAXSizeAttribute, value: AXValueCreate(.cgSize, &size), label: "size")
                }, acceptStableMismatch: false, singleAttempt: policy == .preparedSnap,
                hasLanded: {
                    guard SidebarPlacementGeometry.isValid($0) else { return false }
                    return self.read(expected.id.window, displays: displays, budget: budget,
                        expected: expected, forFocus: allowCovered).window?.scope == destination
                })
        }
        if blocked { result = .cancelled }
        else if nativeFailure != nil { result = .failed("The app rejected this size or position adjustment.") }
        let finalFrame: CGRect?
        let outcome: String
        switch result {
        case .placed(let actual, let adjusted):
            finalFrame = actual
            // A mismatch can be an app clamp or delayed AX state; the captured facts distinguish them.
            outcome = adjusted ? "mismatch" : "matched"
        case .failed(let reason):
            finalFrame = budget.isCurrent ? handle.element.getWindowFrame() : nil
            outcome = "failed:\(reason)"
        case .cancelled:
            finalFrame = nil
            outcome = budget.clock() >= budget.deadline ? "timed-out" : "cancelled"
        }
        let writes = writeResults.joined(separator: ",")
        let final = finalFrame.map { String(describing: $0) } ?? "unavailable"
        let elapsedMilliseconds = Int(max(0, budget.clock() - startedAt) * 1_000)
        if case .placed(_, adjusted: false) = result {
            logger.debug("Resize finish window=\(expected.id.window.windowID, privacy: .public) outcome=\(outcome, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public) final=\(final, privacy: .public) writes=\(writes, privacy: .public)")
        } else {
            logger.notice("Resize finish window=\(expected.id.window.windowID, privacy: .public) outcome=\(outcome, privacy: .public) policy=\(policyName, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public) start=\(String(describing: current.frame), privacy: .public) requested=\(String(describing: frame), privacy: .public) final=\(final, privacy: .public) minimum=\(String(describing: expected.minimum), privacy: .public) minimumReported=\(expected.minimumReported, privacy: .public) writes=\(writes, privacy: .public)")
        }
        return result
    }

    // Presence is separate from visibility: visiting another Desktop or hiding an app
    // must not destroy its tab membership. Only positive native evidence removes a tab.
    func tabPresence(_ identity: WindowLayoutIdentity, budget: WindowControlBudget) -> WindowTabPresence {
        dispatchPrecondition(condition: .onQueue(queue))
        guard budget.isCurrent else { return .unknown }
        guard let app = NSRunningApplication(processIdentifier: identity.window.pid), !app.isTerminated else { return .missing }
        switch resolve(identity.window, budget) {
        case .excluded: return .missing
        case .failed: return .unknown
        case .resolved(let handle):
            guard handle.id == identity else { return .missing }
            var role: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(handle.element, kAXRoleAttribute as CFString, &role)
            if error == .invalidUIElement { return .missing }
            guard budget.isCurrent, error == .success else { return .unknown }
            guard role as? String == kAXWindowRole as String else { return .missing }
            guard let state = readAttributes([kAXMinimizedAttribute, "AXFullScreen"], element: handle.element, budget: budget),
                  let minimized = state[0].optionalBool, let fullScreen = state[1].optionalBool else { return .unknown }
            return minimized || fullScreen ? .separated : .present
        }
    }

    func tabTitle(_ identity: WindowLayoutIdentity, budget: WindowControlBudget) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard budget.isCurrent, case .resolved(let handle) = resolve(identity.window, budget),
              handle.id == identity else { return nil }
        let title: String? = handle.element.getAttributeValue(.title)
        return title?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func closeTab(_ expected: WindowLayoutWindow, displays: [WindowLayoutDisplay], budget: WindowControlBudget) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard budget.isCurrent,
              let current = read(expected.id.window, displays: displays, budget: budget, expected: expected).window,
              current.id == expected.id, current.scope == expected.scope, current.movable,
              case .resolved(let handle) = resolve(expected.id.window, budget), handle.id == expected.id,
              let button: AXUIElement = handle.element.getAttributeValue(.closeButton),
              let enabled: Bool = button.getAttributeValue(.enabled), enabled,
              let owner: AXUIElement = button.getAttributeValue(.window), owner.getWindowID() == expected.id.window.windowID,
              budget.isCurrent else { return false }
        // Ask the app to close normally. It owns save prompts and decides whether it actually closes.
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    static func decodeBulkAttributes(_ values: [AnyObject], expectedCount: Int,
                                     requiredIndices: [Int]) -> [WindowAXAttributeValue]? {
        guard values.count == expectedCount, requiredIndices.allSatisfy({ values.indices.contains($0) }) else { return nil }
        let slots = values.map { WindowAXAttributeValue($0) }
        if requiredIndices.contains(where: { if case .failed = slots[$0] { return true }; return false }) { return slots }
        return requiredIndices.contains(where: { slots[$0].needsIndividualFallback }) ? nil : slots
    }

    private func readAttributes(_ attributes: [String], element: AXUIElement,
                                budget: WindowControlBudget, requiredIndices: [Int] = []) -> [WindowAXAttributeValue]? {
        guard budget.isCurrent else { return nil }
        var array: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &array)
        if result == .success, let values = array as? [AnyObject], values.count == attributes.count {
            // Optional unsupported values have legitimate defaults; required geometry/role is resolved narrowly.
            if let slots = Self.decodeBulkAttributes(values, expectedCount: attributes.count, requiredIndices: requiredIndices) { return slots }
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

    private func readMinimum(_ element: AXUIElement, budget: WindowControlBudget) -> (size: CGSize, reported: Bool)? {
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
            return (size, true)
        }
        return (.zero, false)
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

// A bounded, notification-driven handoff, matching the sidebar's foreground gate.
// It never retries activation or raises after a canceled click or another app switch.
@MainActor
enum WindowPresentation {
    private static let logger = Logger(subsystem: "com.mayank.octopus.local", category: "WindowPresentation")

    private static func failed(_ stage: String, id: SidebarWindowID) -> Bool {
        logger.error("Window presentation failed at \(stage, privacy: .public); pid=\(id.pid) window=\(id.windowID)")
        return false
    }

    static func bringForward(_ id: SidebarWindowID, requirement: SidebarFocusRequirement,
                             token: SidebarPendingAction, queue: DispatchQueue,
                             canContinue: @escaping () -> Bool,
                             validate: @escaping () -> Bool) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: id.pid),
              let launchDate = app.launchDate, requirement.launchDate == launchDate else {
            return failed("launch identity", id: id)
        }
        logger.notice("Window presentation requested; pid=\(id.pid) window=\(id.windowID)")
        func current() -> Bool {
            !Task.isCancelled && token.canFinishFocus(on: id.pid)
                && canContinue() && !app.isTerminated
        }
        func read<T>(_ body: @escaping () -> T) async -> T {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: body()) }
            }
        }
        @Sendable func live() -> Bool {
            guard !token.isCancelled, AXIsProcessTrusted(), !app.isTerminated,
                  app.launchDate == launchDate else { return false }
            let element = requirement.element
            AXUIElementSetMessagingTimeout(element, 0.2)
            var pid: pid_t = 0
            let valid = AXUIElementGetPid(element, &pid) == .success && pid == id.pid
                && element.getWindowID() == id.windowID
                && SidebarWindowPolicy.isTopLevelWindow(role: element.getAttributeValue(.role),
                                                        subrole: element.getAttributeValue(.subrole))
                && validate()
            // Caller validation may use a shorter read timeout. Do not let it
            // shorten the following restore or raise request's timeout.
            AXUIElementSetMessagingTimeout(element, 0.2)
            return valid
        }
        guard current(), await read({
            guard live(), token.beginFocus(),
                  let minimized: Bool = requirement.element.getAttributeValue(.minimized) else { return false }
            if minimized {
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(requirement.element, kAXMinimizedAttribute as CFString,
                                                     &settable) == .success, settable.boolValue,
                      !token.isCancelled,
                      AXUIElementSetAttributeValue(requirement.element, kAXMinimizedAttribute as CFString,
                                                   kCFBooleanFalse) == .success else { return false }
            }
            return !token.isCancelled
        }), current() else { return failed("validation or restoration", id: id) }
        if app.isHidden {
            guard app.unhide(), current() else { return failed("unhide", id: id) }
        }
        let activated = await withCheckedContinuation { continuation in
            let waiter = WindowForegroundActivationWaiter(targetPID: id.pid, initialPID: token.frontmostPID,
                center: NSWorkspace.shared.notificationCenter, timeout: 1, canContinue: current,
                frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
                    continuation.resume(returning: $0)
                }
            waiter.start { SidebarFocusActivation.requestForeground(app, target: id, token: token) }
        }
        guard activated, current() else { return failed("activation", id: id) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        guard await read({
            guard live() else { return failed("validation before raise", id: id) }
            return SidebarFocusActivation.raise(requirement.element, id: id, token: token, expiresAt: deadline)
        }), current() else { return failed("raise", id: id) }
        while current(), ProcessInfo.processInfo.systemUptime < deadline {
            let confirmed = await read {
                guard live(), !app.isHidden,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == id.pid else { return false }
                let application = AXUIElementCreateApplication(id.pid)
                AXUIElementSetMessagingTimeout(application, 0.1)
                guard let focused: AXUIElement = application.getAttributeValue(.focusedWindow) else { return false }
                AXUIElementSetMessagingTimeout(focused, 0.1)
                return requirement.matches(element: focused, launchDate: app.launchDate)
                    && focused.getWindowID() == id.windowID
                    && SidebarWindowReader.isOnScreen(id)
            }
            if confirmed {
                logger.notice("Window presentation verified focused and on-screen; pid=\(id.pid) window=\(id.windowID)")
                return current()
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return failed("focused-window confirmation", id: id)
    }
}

@MainActor
final class WindowForegroundActivationWaiter {
    private let targetPID: pid_t
    private let initialPID: pid_t?
    private let center: NotificationCenter
    private let canContinue: () -> Bool
    private let frontmostPID: () -> pid_t?
    private let timeout: TimeInterval
    private let completion: (Bool) -> Void
    private var observer: NSObjectProtocol?
    private var expiry: DispatchWorkItem?
    private var completed = false

    init(targetPID: pid_t, initialPID: pid_t?, center: NotificationCenter,
         timeout: TimeInterval = 2, canContinue: @escaping () -> Bool,
         frontmostPID: @escaping () -> pid_t?, completion: @escaping (Bool) -> Void) {
        self.targetPID = targetPID
        self.initialPID = initialPID
        self.center = center
        self.timeout = timeout
        self.canContinue = canContinue
        self.frontmostPID = frontmostPID
        self.completion = completion
    }

    func start(requestActivation: () -> Bool) {
        guard !completed, observer == nil else { return }
        guard canContinue() else { finish(false); return }
        // Registration precedes the request, including apps that activate synchronously.
        // Observer/expiry retain this short-lived request until finish removes both.
        observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [self] _ in
            MainActor.assumeIsolated { activationChanged() }
        }
        let work = DispatchWorkItem { [self] in finish(false) }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        guard requestActivation() else { finish(false); return }
        activationChanged()
    }

    private func activationChanged() {
        guard !completed else { return }
        guard canContinue() else { finish(false); return }
        let current = frontmostPID()
        if current == targetPID { finish(true) }
        else if current != initialPID { finish(false) }
    }

    private func finish(_ activated: Bool) {
        guard !completed else { return }
        completed = true
        if let observer { center.removeObserver(observer) }
        observer = nil
        expiry?.cancel()
        expiry = nil
        completion(activated)
    }
}
