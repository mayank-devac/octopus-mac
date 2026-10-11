import AppKit

enum WindowMonitorMoveDirection { case left, right }

struct WindowMonitorMovePlan {
    let source: WindowLayoutWindow
    let destination: WindowLayoutScope
    let frame: CGRect
    let workArea: CGRect
    let resize: Bool
}

enum WindowMonitorMoveOutcome {
    case moved(WindowLayoutWindow, adjusted: Bool)
    case failed(String)
    case cancelled
}

enum WindowMonitorMovePolicy {
    static func destination(from sourceID: String, direction: WindowMonitorMoveDirection,
                            displays: [WindowLayoutDisplay]) -> WindowLayoutDisplay? {
        guard displays.count > 1, Set(displays.map(\.id)).count == displays.count else { return nil }
        // Screen enumeration follows the menu-bar display, not the physical arrangement.
        // Vertically stacked monitors use top-to-bottom order as a stable tie-breaker.
        let ordered = displays.sorted {
            if $0.frame.midX != $1.frame.midX { return $0.frame.midX < $1.frame.midX }
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            return $0.id < $1.id
        }
        guard let index = ordered.firstIndex(where: { $0.id == sourceID }) else { return nil }
        let offset = direction == .left ? -1 : 1
        return ordered[(index + offset + ordered.count) % ordered.count]
    }

    static func plan(window: WindowLayoutWindow, sourceArea: CGRect, destination: WindowLayoutDisplay,
                     scope: WindowLayoutScope, moveSize: VisibleDisplayMoveSize) -> WindowMonitorMovePlan? {
        guard window.movable, window.scope.displayID != destination.id, scope.displayID == destination.id,
              SidebarPlacementGeometry.isValid(window.frame), SidebarPlacementGeometry.isValid(sourceArea),
              SidebarPlacementGeometry.isValid(destination.workArea) else { return nil }
        let frame: CGRect
        if window.canResize && moveSize == .fullScreen {
            frame = destination.workArea
        } else {
            // Keep both size and relative position. Preserve oversized fixed-size windows;
            // the existing native writer keeps their title bars reachable and reports limits.
            func relative(_ position: CGFloat, origin: CGFloat, travel: CGFloat) -> CGFloat {
                travel > 0 ? min(1, max(0, (position - origin) / travel)) : 0
            }
            let x = relative(window.frame.minX, origin: sourceArea.minX, travel: sourceArea.width - window.frame.width)
            let y = relative(window.frame.minY, origin: sourceArea.minY, travel: sourceArea.height - window.frame.height)
            frame = CGRect(x: destination.workArea.minX + x * max(0, destination.workArea.width - window.frame.width),
                           y: destination.workArea.minY + y * max(0, destination.workArea.height - window.frame.height),
                           width: window.frame.width, height: window.frame.height)
        }
        return WindowMonitorMovePlan(source: window, destination: scope, frame: frame,
                                     workArea: destination.workArea, resize: window.canResize)
    }

    static func execute(_ plan: WindowMonitorMovePlan, canContinue: () -> Bool,
                        read: (WindowLayoutWindow) -> WindowLayoutWindow?,
                        write: (WindowMonitorMovePlan) -> SidebarPlacementResult,
                        wait: () -> Void = { Thread.sleep(forTimeInterval: 0.025) }) -> WindowMonitorMoveOutcome {
        guard canContinue() else { return .cancelled }
        guard let current = read(plan.source), current.id == plan.source.id, current.movable,
              current.scope == plan.source.scope, (!plan.resize || current.canResize),
              SidebarPlacementGeometry.matches(current.frame, plan.source.frame) else {
            return .failed("The focused window changed before it could be moved.")
        }
        guard canContinue() else { return .cancelled }
        let result = write(plan)
        guard canContinue() else { return .cancelled }
        switch result {
        case .cancelled: return .cancelled
        case .failed(let reason): return .failed(reason)
        case .placed(let achieved, let adjusted):
            // Frame and native Desktop membership can settle separately. Retry observations
            // only; never resubmit a move or invent an automatic rollback after a partial result.
            for poll in 0..<SidebarPlacementWriter.maximumSettlePolls {
                guard canContinue() else { return .cancelled }
                if let actual = read(plan.source) {
                    guard actual.id == plan.source.id, actual.movable else {
                        return .failed("The window changed while its monitor move was being confirmed.")
                    }
                    if actual.scope == plan.destination, SidebarPlacementGeometry.matches(actual.frame, achieved) {
                        guard canContinue() else { return .cancelled }
                        return .moved(actual, adjusted: adjusted || !SidebarPlacementGeometry.matches(actual.frame, plan.frame))
                    }
                }
                if poll < SidebarPlacementWriter.maximumSettlePolls - 1 { wait() }
            }
            return .failed("Couldn’t confirm the monitor move. The window may have moved.")
        }
    }
}

@MainActor
final class WindowMonitorMoveController {
    // No periodic inventory or all-app scan. This reader resolves only the front app's exact window.
    private let reader = SidebarWindowReader(onChange: {})
    private let feedback = WindowPlacementFeedback()
    private var token: WindowLayoutBatchToken?
    private var requestStartedAt: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            })
        observers.append(center.addObserver(forName: WindowLayoutController.userActionNotification,
            object: nil, queue: .main) { [weak self] note in
                let startedAt = note.object as? TimeInterval ?? ProcessInfo.processInfo.systemUptime
                Task { @MainActor in
                    guard let self, startedAt > self.requestStartedAt else { return }
                    self.cancel()
                }
            })
        let workspace = NSWorkspace.shared.notificationCenter
        // Visible Space IDs are rechecked at the native setters. A focus handoff between
        // two already visible monitors must not be mistaken for a desktop-switch cancellation.
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            })
        }
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let token = self.token,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier != token.frontmostPID else { return }
                    self.cancel()
                }
            })
    }

    func move(_ direction: WindowMonitorMoveDirection) {
        guard running, token == nil else { return } // Busy presses are ignored, never queued.
        let displays = WindowLayoutDisplay.connected()
        guard displays.count > 1 else { return }
        guard AXIsProcessTrusted() else {
            feedback.showFeedback("Enable Accessibility access for Octopus to move windows.")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isHidden else { return }
        feedback.stop()
        requestStartedAt = ProcessInfo.processInfo.systemUptime
        NotificationCenter.default.post(name: WindowLayoutController.userActionNotification, object: requestStartedAt)
        let batch = WindowLayoutBatchToken(frontmostPID: app.processIdentifier)
        token = batch
        let budget = WindowControlBudget(deadline: requestStartedAt + 4, canContinue: { !batch.isCancelled })
        let moveSize = WindowLayoutSettings.moveSize()
        reader.queue.async { [weak self, reader] in
            let access = reader.windowControlAccess
            var result = Self.perform(pid: app.processIdentifier, direction: direction, displays: displays,
                                      moveSize: moveSize, access: access, budget: budget)
            if !batch.isCancelled {
                if !AXIsProcessTrusted() {
                    result = .failed("Accessibility access changed during the move. Check the window’s location.")
                } else if budget.clock() >= budget.deadline {
                    result = .failed("The app took too long to finish the move. Check the window’s location.")
                }
            }
            let completedResult = result
            DispatchQueue.main.async {
                guard let self, self.token === batch else { return }
                self.token = nil
                guard self.running, !batch.isCancelled else { return }
                switch completedResult {
                case .cancelled: break
                case .failed(let message): self.feedback.showFeedback(message)
                case .moved(let window, let adjusted):
                    if adjusted {
                        let screen = NSScreen.screens.first { SidebarSettings.monitorID($0) == window.scope.displayID }
                        self.feedback.showFeedback("The window moved, but the app limited its size or position.", on: screen)
                    }
                }
            }
        }
    }

    // All AX reads, writes and final focus confirmation stay on the native reader's serial queue.
    private nonisolated static func perform(pid: pid_t, direction: WindowMonitorMoveDirection,
                                           displays: [WindowLayoutDisplay], moveSize: VisibleDisplayMoveSize,
                                           access: WindowControlAccess, budget: WindowControlBudget) -> WindowMonitorMoveOutcome {
        guard budget.isCurrent else { return .cancelled }
        guard let id = access.focusedWindowID(pid: pid, budget: budget) else {
            return .failed("No movable focused window was found.")
        }
        let window: WindowLayoutWindow
        switch access.read(id, displays: displays, budget: budget) {
        case .window(let value): window = value
        case .failed(let reason): return .failed(reason)
        case .excluded: return .failed("The focused window is not a normal window on a visible desktop.")
        }
        guard window.movable else {
            return .failed("The focused window cannot be moved. Full-screen windows and dialogs are excluded.")
        }
        guard let source = displays.first(where: { $0.id == window.scope.displayID }),
              let destination = WindowMonitorMovePolicy.destination(from: source.id, direction: direction, displays: displays) else {
            return .failed("The window’s monitor could not be identified.")
        }
        guard let scope = access.visibleScope(on: destination.id, budget: budget) else {
            return .failed("The next monitor must show a normal desktop. Its desktop will not be switched.")
        }
        guard let plan = WindowMonitorMovePolicy.plan(window: window, sourceArea: source.workArea,
            destination: destination, scope: scope, moveSize: moveSize) else {
            return .failed("This window cannot be moved to the next monitor.")
        }
        let result = WindowMonitorMovePolicy.execute(plan, canContinue: { budget.isCurrent }, read: {
            access.read($0.id.window, displays: displays, budget: budget, expected: $0).window
        }, write: { plan in
            access.write(plan.source, frame: plan.frame, workArea: plan.workArea, destination: plan.destination,
                displays: displays, budget: budget, policy: .crossDisplayPlacement,
                resize: plan.resize, requireFocused: true)
        })
        guard case .moved(let actual, _) = result else { return result }
        guard access.raiseFocused(actual, displays: displays, budget: budget) else {
            if !budget.isCurrent || access.focusedWindowID(pid: pid, budget: budget) != id { return .cancelled }
            return .failed("The window moved, but its final focus could not be confirmed.")
        }
        return result
    }

    private func cancel() {
        // Keep the busy guard until the queued native operation returns, even after cancellation.
        token?.cancel()
    }

    func stop() {
        running = false
        cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        workspaceObservers.removeAll()
        feedback.stop()
    }
}
