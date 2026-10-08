import AppKit
import Combine
import os

@MainActor
final class WindowLayoutController: ObservableObject {
    static let completedSnapNotification = Notification.Name("octopus.completedSnap")
    static let userActionNotification = Notification.Name("octopus.windowAction")

    @Published private(set) var status = ""
    @Published private(set) var canUndo = false
    private let reader = SidebarWindowReader(onChange: {}, tracksFrontmostFocus: true)
    private let feedbackInventory = SidebarWindowInventory()
    private lazy var feedback = SidebarDragController(inventory: feedbackInventory)
    private let logger = Logger(subsystem: "com.mayank.octopus", category: "WindowLayout")
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var token: WindowLayoutBatchToken?
    private var inputMonitor: Any?
    private var localInputMonitor: Any?
    private var generation = 0
    private var latestAction: TimeInterval = 0
    private var enabled = false
    private var selection = WindowLayoutSelection.mostRecent
    private var trackingRefreshQueued = false
    private var undo: (plan: WindowLayoutPlan, achieved: [WindowLayoutIdentity: CGRect])?
    private var pairUndo: WindowPairUndoRecord?

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Self.completedSnapNotification, object: nil, queue: .main) { [weak self] note in
            guard let snap = note.object as? WindowLayoutCompletedSnap else { return }
            Task { @MainActor in self?.schedule(snap) }
        })
        observers.append(center.addObserver(forName: Self.userActionNotification, object: nil, queue: .main) { [weak self] note in
            let startedAt = note.object as? TimeInterval ?? ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                self?.latestAction = max(self?.latestAction ?? 0, startedAt)
                self?.cancel()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                self.reader.queue.async { [reader = self.reader] in reader.recordFrontmostWindow(pid: pid) }
            }
        })
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.cancel()
                    self?.refreshTracking()
                }
            })
        }
        applySettings()
    }

    private func applySettings() {
        let next = WindowLayoutSettings.enabled()
        let nextSelection = WindowLayoutSettings.selection()
        guard next != enabled || nextSelection != selection else { return }
        enabled = next
        selection = nextSelection
        cancel()
        status = ""
        if next { refreshTracking() }
        else { reader.queue.async { [reader] in reader.removeObservers() } }
    }

    // Baseline discovery only records focus; it never rearranges existing windows on launch.
    private func refreshTracking() {
        guard enabled, !trackingRefreshQueued else { return }
        trackingRefreshQueued = true
        let apps = applications()
        let focused = NSWorkspace.shared.frontmostApplication?.processIdentifier
        reader.queue.async { [weak self, reader] in
            reader.trackLayoutFocus(apps)
            if let focused { reader.recordFrontmostWindow(pid: focused) }
            DispatchQueue.main.async { self?.trackingRefreshQueued = false }
        }
    }

    private func applications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    private func schedule(_ snap: WindowLayoutCompletedSnap) {
        guard enabled, snap.request.snap != .maximize, snap.isCurrent(after: latestAction) else { return }
        cancel()
        // The native writer already confirmed its frame. Prepare companions on the next turn.
        let work = DispatchWorkItem { [weak self] in self?.adjust(snap) }
        pending = work
        DispatchQueue.main.async(execute: work)
    }

    // Hover preparation is read-only; the drag session decides whether this result is still relevant.
    @discardableResult func preparePair(source: SidebarWindowID, target: SidebarWindowID,
                     completion: @escaping (WindowPairPreparation?) -> Void) -> WindowLayoutBatchToken {
        let displays = WindowLayoutDisplay.connected()
        let token = WindowLayoutBatchToken(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let budget = WindowControlBudget(deadline: ProcessInfo.processInfo.systemUptime + 0.8,
            canContinue: { !token.isCancelled })
        reader.queue.async { [reader] in
            let prepared = WindowPairSnapService.prepare(source: source, target: target,
                displays: displays, access: reader.windowControlAccess, budget: budget)
            DispatchQueue.main.async { completion(prepared) }
        }
        return token
    }

    // An icon pair is an explicit two-window command, independent of automatic companion settings.
    func snapPair(_ request: WindowPairSnapRequest) {
        guard request.isCurrent(after: latestAction), AXIsProcessTrusted() else { return }
        cancel()
        latestAction = request.startedAt
        let batch = WindowLayoutBatchToken(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        token = batch
        watchInput(batch)
        let displays = WindowLayoutDisplay.connected()
        let budget = WindowControlBudget(deadline: ProcessInfo.processInfo.systemUptime + 4,
            canContinue: { !batch.isCancelled && NSWorkspace.shared.frontmostApplication?.processIdentifier == batch.frontmostPID })
        reader.queue.async { [weak self, reader] in
            let access = reader.windowControlAccess
            var outcome = WindowPairResult.stopped("The selected windows could not be paired safely.")
            var plan: WindowPairSnapPlan?
            if let prepared = WindowPairSnapService.prepare(source: request.source, target: request.target,
                displays: displays, access: access, budget: budget),
               let pair = WindowLayoutPlanner.pair(source: prepared.source, target: prepared.target,
                    direction: request.direction, display: prepared.display) {
                plan = pair
                outcome = WindowPairSnapService.execute(pair, canContinue: { budget.isCurrent },
                    read: { access.read($0.id.window, displays: displays, budget: budget, expected: $0).window },
                    write: { window, frame, scope in
                        access.write(window, frame: frame, workArea: pair.workArea, destination: scope,
                            displays: displays, budget: budget,
                            policy: window.scope.displayID == scope.displayID ? .sameDisplayAdjustment : .crossDisplayPlacement)
                    })
            }
            DispatchQueue.main.async {
                guard let self, self.token === batch else { return }
                guard !batch.isCancelled else { self.finishInput(); self.token = nil; return }
                switch outcome {
                case .applied(let source, let target):
                    guard let plan else { self.finishInput(); self.token = nil; return }
                    self.pairUndo = WindowPairUndoRecord(plan: plan, sourceAfter: source, targetAfter: target)
                    self.canUndo = true
                    self.status = "Paired the two selected windows on the target display and Desktop."
                    // Keep input cancellation through the follow-up raise so a new click cannot lose focus to it.
                    access.focusConfirmed(source, token: batch) { [weak self] in
                        guard let self, self.token === batch else { return }
                        self.finishInput()
                    }
                case .stopped(let reason): self.finishInput(); self.token = nil; self.report(reason)
                }
            }
        }
    }

    private func adjust(_ snap: WindowLayoutCompletedSnap) {
        pending = nil
        guard enabled, AXIsProcessTrusted() else { return }
        let requestGeneration = generation
        let batch = WindowLayoutBatchToken(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        token = batch
        watchInput(batch)
        let displays = WindowLayoutDisplay.connected()
        let selection = self.selection
        let logger = self.logger
        reader.queue.async { [weak self, reader] in
            guard !batch.isCancelled else {
                DispatchQueue.main.async {
                    guard let self, self.token === batch else { return }
                    self.finishInput()
                    self.token = nil
                }
                return
            }
            let snapshot = reader.layoutSnapshot(displays: displays, desktop: requestGeneration, snap: snap, selection: selection)
            let planning = WindowLayoutPlanner.plan(snapshot: snapshot, anchorID: snap.window, request: snap.request, selection: selection)
            var result: WindowLayoutBatchResult?
            var plan: WindowLayoutPlan?
            if case .ready(let ready) = planning {
                plan = ready
                logger.notice("Planning anchor \(ready.anchor.id.window.windowID, privacy: .public), peers \(String(describing: ready.peers.map { $0.id.window.windowID }), privacy: .public), targets \(String(describing: ready.frames), privacy: .public)")
                result = Self.execute(ready, reader: reader, displays: displays, batch: batch)
            }
            DispatchQueue.main.async {
                guard let self, self.token === batch, requestGeneration == self.generation else { return }
                self.finishInput()
                self.token = nil
                guard !batch.isCancelled else { return }
                switch planning {
                case .noPeer: self.status = "No other normal window on this display and Desktop."
                case .rejected(let reason): self.report(reason)
                case .ready:
                    guard let plan, let result else { return }
                    switch result {
                    case .applied(let actual):
                        self.undo = (plan, actual)
                        self.canUndo = true
                        self.status = "Adjusted \(plan.peers.count) other window\(plan.peers.count == 1 ? "" : "s") in the opposite half."
                        self.logger.notice("Adjusted \(plan.peers.count, privacy: .public) peers, display \(plan.scope.displayID, privacy: .public), Desktop \(plan.scope.spaceID, privacy: .public), anchor \(String(describing: plan.anchor.frame), privacy: .public), actual \(String(describing: actual), privacy: .public)")
                    case .stopped(let reason): self.report(reason)
                    }
                }
            }
        }
    }

    nonisolated private static func execute(_ plan: WindowLayoutPlan, reader: SidebarWindowReader,
                                           displays: [WindowLayoutDisplay], batch: WindowLayoutBatchToken) -> WindowLayoutBatchResult {
        func canContinue() -> Bool {
            let focused = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return !batch.isCancelled && AXIsProcessTrusted()
                && (focused == batch.frontmostPID || focused == plan.anchor.id.window.pid)
        }
        return WindowLayoutExecutor.apply(plan, canContinue: canContinue,
            read: { id in
                guard let expected = ([plan.anchor] + plan.peers).first(where: { $0.id == id }) else { return nil }
                return reader.currentLayoutWindow(expected, displays: displays)
            },
            write: { id, frame, deadline in
                guard let peer = plan.peers.first(where: { $0.id == id }) else { return .cancelled }
                let result = reader.writeLayoutWindow(peer, frame: frame, workArea: plan.workArea,
                    displays: displays, token: batch, anchorPID: plan.anchor.id.window.pid, deadline: deadline)
                #if DEBUG
                let logger = Logger(subsystem: "com.mayank.octopus", category: "WindowLayout")
                logger.notice("Writer peer \(id.window.windowID, privacy: .public), requested \(String(describing: frame), privacy: .public), result \(String(describing: result), privacy: .public)")
                #endif
                return result
            })
    }

    func undoAdjustment() {
        if let pairUndo { undoPair(pairUndo); return }
        guard enabled, let undo else { return }
        cancel()
        let batch = WindowLayoutBatchToken(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        token = batch
        watchInput(batch)
        let displays = WindowLayoutDisplay.connected()
        reader.queue.async { [weak self, reader] in
            let current = undo.plan.peers.compactMap { reader.layoutWindow($0.id.window, displays: displays) }
            let anchor = reader.layoutWindow(undo.plan.anchor.id.window, displays: displays)
            var result = WindowLayoutBatchResult.stopped("Undo is unavailable because the windows or Desktop changed.")
            if current.count == undo.plan.peers.count,
               current.allSatisfy({ window in
                   guard let achieved = undo.achieved[window.id] else { return false }
                   return window.scope == undo.plan.scope && window.eligible && SidebarPlacementGeometry.matches(window.frame, achieved)
               }), let anchor, anchor.id == undo.plan.anchor.id, anchor.scope == undo.plan.scope,
               SidebarPlacementGeometry.matches(anchor.frame, undo.plan.anchor.frame) {
                let reverse = WindowLayoutPlan(scope: undo.plan.scope, desktopGeneration: undo.plan.desktopGeneration,
                    workArea: undo.plan.workArea, anchor: anchor, peers: current,
                    frames: Dictionary(uniqueKeysWithValues: undo.plan.peers.map { ($0.id, $0.frame) }))
                result = WindowLayoutExecutor.apply(reverse,
                    canContinue: { !batch.isCancelled && AXIsProcessTrusted()
                        && NSWorkspace.shared.frontmostApplication?.processIdentifier == batch.frontmostPID },
                    read: { reader.layoutWindow($0.window, displays: displays) },
                    write: { id, frame, deadline in
                        guard let peer = current.first(where: { $0.id == id }) else { return .cancelled }
                        return reader.writeLayoutWindow(peer, frame: frame, workArea: reverse.workArea,
                            displays: displays, token: batch, anchorPID: batch.frontmostPID ?? 0, deadline: deadline)
                    }, restoring: true)
            }
            DispatchQueue.main.async {
                guard let self, self.token === batch else { return }
                self.finishInput()
                self.token = nil
                switch result {
                case .applied: self.status = "The adjusted windows returned to their previous positions."
                case .stopped(let reason): if !batch.isCancelled { self.report(reason) }
                }
            }
        }
    }

    // Pair Undo restores both original visible scopes; ordinary snap Undo remains companion-only.
    private func undoPair(_ record: WindowPairUndoRecord) {
        cancel()
        let batch = WindowLayoutBatchToken(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        token = batch
        watchInput(batch)
        let displays = WindowLayoutDisplay.connected()
        let budget = WindowControlBudget(deadline: ProcessInfo.processInfo.systemUptime + 4,
            canContinue: { !batch.isCancelled && NSWorkspace.shared.frontmostApplication?.processIdentifier == batch.frontmostPID })
        reader.queue.async { [weak self, reader] in
            let access = reader.windowControlAccess
            let outcome = WindowPairSnapService.undo(record, canContinue: { budget.isCurrent },
                scopeVisible: { access.scopeIsVisible($0, displays: displays) },
                read: { access.read($0.id.window, displays: displays, budget: budget, expected: $0).window },
                write: { window, frame, scope in
                    guard let display = displays.first(where: { $0.id == scope.displayID }) else { return .cancelled }
                    return access.write(window, frame: frame, workArea: display.workArea, destination: scope,
                        displays: displays, budget: budget,
                        policy: window.scope.displayID == scope.displayID ? .sameDisplayAdjustment : .crossDisplayPlacement)
                })
            DispatchQueue.main.async {
                guard let self, self.token === batch else { return }
                self.finishInput()
                self.token = nil
                guard !batch.isCancelled else { return }
                switch outcome {
                case .applied: self.status = "Both paired windows returned to their previous positions."
                case .stopped(let reason): self.report(reason)
                }
            }
        }
    }

    private func watchInput(_ batch: WindowLayoutBatchToken) {
        // Either Octopus or another app may have focus while native writes are pending.
        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { event in
            batch.cancel()
            return event
        }
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { _ in
            batch.cancel()
        }
    }

    private func finishInput() {
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }
        localInputMonitor = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    private func report(_ reason: String) {
        status = reason
        feedback.showFeedback(reason)
        logger.notice("Neighbour adjustment declined: \(reason, privacy: .public)")
    }

    private func cancel() {
        generation += 1
        pending?.cancel()
        pending = nil
        token?.cancel()
        token = nil
        finishInput()
        undo = nil
        pairUndo = nil
        canUndo = false
        status = ""
    }

    func stop() {
        cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        workspaceObservers.removeAll()
        reader.queue.async { [reader] in reader.removeObservers() }
        feedback.stop()
    }
}
