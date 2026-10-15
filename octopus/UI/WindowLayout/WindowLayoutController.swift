import AppKit
import Combine
import os

@MainActor
final class WindowLayoutController: ObservableObject {
    static let completedSnapNotification = Notification.Name("octopus.completedSnap")
    static let userActionNotification = Notification.Name("octopus.windowAction")

    @Published private(set) var status = ""
    @Published private(set) var canUndo = false
    // Only inactive tabs are excluded; the active window represents its group.
    var tabSnapExclusions: (SidebarWindowID) -> Set<SidebarWindowID> = { _ in [] }
    var tabGroupMinimums: () -> [SidebarWindowID: CGSize] = { [:] }
    var onPairLayoutAttempted: (SidebarWindowID, SidebarWindowID) -> Void = { _, _ in }
    private let reader = SidebarWindowReader(onChange: {}, tracksFrontmostFocus: true)
    private let feedback = WindowPlacementFeedback()
    private let logger = Logger(subsystem: "com.mayank.octopus", category: "WindowLayout")
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var token: WindowLayoutBatchToken?
    private var snapPreparation: WindowLayoutBatchToken?
    private var inputMonitor: Any?
    private var localInputMonitor: Any?
    private var tabPlacement: WindowTabPlacementActivity?
    private var generation = 0
    private var latestAction: TimeInterval = 0
    private var enabled = false
    private var selection = WindowLayoutSelection.mostRecent
    private var maximumWindows = WindowLayoutSettings.defaultMaximumWindows
    private var snapMode = WindowSnapMode.legacy
    private var trackingRefreshQueued = false
    private var undo: (plan: WindowLayoutPlan, achieved: [WindowLayoutIdentity: CGRect], participants: Set<WindowLayoutIdentity>?)?
    private var pairUndo: WindowPairUndoRecord?
    private struct LearnedConstraint {
        let scope: WindowLayoutScope
        let workArea: CGRect
        let value: WindowLayoutSizeConstraint
        let recordedAt: TimeInterval
    }
    // Keep learned app limits temporary: the same window can change its content and size rules.
    private static let constraintCacheLifetime: TimeInterval = 120
    private static let maximumCachedConstraints = 128
    private var learnedConstraints: [WindowLayoutIdentity: LearnedConstraint] = [:]

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Self.completedSnapNotification, object: nil, queue: .main) { [weak self] note in
            guard let snap = note.object as? WindowLayoutCompletedSnap else { return }
            Task { @MainActor in self?.schedule(snap) }
        })
        observers.append(center.addObserver(forName: Self.userActionNotification, object: nil, queue: .main) { [weak self] note in
            let startedAt = note.object as? TimeInterval ?? ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated {
                self?.latestAction = max(self?.latestAction ?? 0, startedAt)
                self?.cancel()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(); self?.learnedConstraints.removeAll() }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
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
                MainActor.assumeIsolated {
                    self?.cancel()
                    self?.learnedConstraints.removeAll()
                    self?.refreshTracking()
                }
            })
        }
        applySettings()
    }

    private func applySettings() {
        let next = WindowLayoutSettings.enabled()
        let nextSelection = WindowLayoutSettings.selection()
        let nextMaximumWindows = WindowLayoutSettings.maximumWindows()
        let nextMode = WindowLayoutSettings.mode()
        let trackingChanged = next != enabled || nextSelection != selection
        guard next != enabled || nextSelection != selection || nextMaximumWindows != maximumWindows || nextMode != snapMode else { return }
        enabled = next
        selection = nextSelection
        maximumWindows = nextMaximumWindows
        snapMode = nextMode
        cancel()
        status = ""
        if next {
            if trackingChanged { refreshTracking() }
        } else { reader.queue.async { [reader] in reader.removeObservers() } }
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
        guard enabled, snapMode == .legacy, snap.request.snap != .maximize, snap.isCurrent(after: latestAction) else { return }
        if snap.request.snap?.isCorner == true && selection == .mostRecent { return }
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

    @discardableResult func prepareSnap(window: SidebarWindowID, request: SidebarPlacementRequest,
                         completion: @escaping (WindowLayoutPreparedSnap?) -> Void) -> WindowLayoutBatchToken {
        snapPreparation?.cancel()
        let displays = WindowLayoutDisplay.connected()
        let settings = WindowSnapSettings.current()
        let grouped = tabSnapExclusions(window)
        let groupMinimums = tabGroupMinimums()
        let revision = generation
        let batch = WindowLayoutBatchToken(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        snapPreparation = batch
        // Queueing, candidate reads and allocation share this bounded read-only budget.
        let budget = WindowControlBudget(deadline: ProcessInfo.processInfo.systemUptime + 0.8,
            canContinue: { !batch.isCancelled && NSWorkspace.shared.frontmostApplication?.processIdentifier == batch.frontmostPID })
        reader.queue.async { [weak self, reader] in
            let access = reader.windowControlAccess
            let foregroundWindow = batch.frontmostPID.flatMap { access.focusedWindowID(pid: $0, budget: budget) }
            var prepared: WindowLayoutPreparedSnap?
            if let display = displays.first(where: { SidebarPlacementGeometry.matches($0.workArea, request.workArea) }),
               let scope = access.visibleScope(on: display.id, budget: budget),
               let nativeAnchor = access.read(window, displays: displays, budget: budget).window {
                let anchor = Self.respectingTabMinimum(nativeAnchor, minimums: groupMinimums)
                var snapshot: WindowLayoutSnapshot?
                var preferred: SidebarWindowID?
                if settings.enabled && !(request.snap?.isCorner == true && settings.selection == .mostRecent) {
                    preferred = foregroundWindow
                    let snap = WindowLayoutCompletedSnap(window: window, request: request,
                        startedAt: ProcessInfo.processInfo.systemUptime, achievedFrame: anchor.frame, preferredCompanion: preferred)
                    snapshot = reader.layoutSnapshot(displays: displays, desktop: revision, snap: snap,
                        selection: settings.selection, maximumWindows: settings.maximumWindows, budget: budget, preparingFor: scope,
                        excluding: grouped)
                    if let native = snapshot { snapshot = Self.respectingTabMinimum(native, minimums: groupMinimums) }
                }
                // A slow companion cannot block a primary window already read successfully.
                // Keep its original snapshot; commit will revalidate it under a fresh write budget.
                if !budget.isCurrent { snapshot = nil }
                if !batch.isCancelled, AXIsProcessTrusted(),
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == batch.frontmostPID,
                   let selected = WindowLayoutPlanner.preparedPlan(snapshot: snapshot, anchor: anchor,
                    request: request, destination: scope, display: display, settings: settings,
                    generation: revision, preferredCompanion: preferred) {
                    prepared = WindowLayoutPreparedSnap(plan: selected.plan, request: request, displays: displays,
                        settings: settings, generation: revision, frontmostPID: batch.frontmostPID,
                        frontmostWindow: foregroundWindow,
                        fallbackReason: selected.fallbackReason)
                }
            }
            let result = prepared
            DispatchQueue.main.async {
                guard let self, self.snapPreparation === batch else { completion(nil); return }
                guard !batch.isCancelled, self.generation == revision,
                      WindowSnapSettings.current() == settings else {
                    self.snapPreparation = nil
                    completion(nil)
                    return
                }
                // Keep the ready token so a Desktop/screen/settings change invalidates the visible preview too.
                if result == nil { self.snapPreparation = nil }
                completion(result)
            }
        }
        return batch
    }

    // No legacy completedSnap notification is emitted: this operation already includes its companions.
    func commitSnap(_ prepared: WindowLayoutPreparedSnap) {
        let displays = WindowLayoutDisplay.connected()
        guard prepared.settings.mode == .current,
              prepared.isCurrent(generation: generation, settings: .current(), displays: displays,
              frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier), AXIsProcessTrusted() else {
            report("The preview changed; no windows were moved. Drag again.")
            return
        }
        cancel()
        latestAction = ProcessInfo.processInfo.systemUptime
        let batch = WindowLayoutBatchToken(frontmostPID: prepared.frontmostPID)
        token = batch
        watchInput(batch)
        let plan = prepared.plan
        let groupMinimums = tabGroupMinimums()
        let activity = WindowTabPlacementActivity()
        tabPlacement = activity
        NotificationCenter.default.post(name: WindowTabPlacementActivity.began, object: activity)
        let budget = WindowControlBudget(deadline: ProcessInfo.processInfo.systemUptime + 4,
            canContinue: { !batch.isCancelled && NSWorkspace.shared.frontmostApplication?.processIdentifier == batch.frontmostPID })
        reader.queue.async { [weak self, reader] in
            let access = reader.windowControlAccess
            let foregroundUnchanged = prepared.frontmostWindow.map {
                access.focusedWindowID(pid: $0.pid, budget: budget) == $0
            } ?? true
            let outcome = foregroundUnchanged ? WindowLayoutExecutor.applyPrepared(plan, canContinue: { budget.isCurrent },
                read: { window in
                    access.read(window.id.window, displays: displays, budget: budget).window.map {
                        Self.respectingTabMinimum($0, minimums: groupMinimums)
                    }
                },
                write: { window, frame in
                    access.write(window, frame: frame, workArea: plan.workArea, destination: plan.scope,
                        displays: displays, budget: budget, policy: .preparedSnap,
                        snap: window.id == plan.anchor.id ? plan.snap : nil)
                }) : WindowLayoutSnapResult(reason: "The focused window changed; no windows were moved. Drag again.")
            let focusCandidate: WindowLayoutWindow?
            if let achieved = outcome.achieved[plan.anchor.id], budget.isCurrent,
               prepared.frontmostWindow.map({ access.focusedWindowID(pid: $0.pid, budget: budget) == $0 }) ?? true,
               let live = access.read(achieved.id.window, displays: displays, budget: budget, expected: achieved).window,
               live.id == achieved.id, live.scope == achieved.scope, live.eligible,
               SidebarPlacementGeometry.matches(live.frame, achieved.frame) { focusCandidate = live }
            else { focusCandidate = nil }
            DispatchQueue.main.async {
                guard let self, self.token === batch else { return }
                guard !batch.isCancelled else { self.finishInput(); self.token = nil; return }
                // Undo only verified changed companions; it never returns the dragged window to another display.
                let achievedPeers = Dictionary(uniqueKeysWithValues: plan.peers.compactMap { original -> (WindowLayoutIdentity, CGRect)? in
                    guard let actual = outcome.achieved[original.id],
                          !SidebarPlacementGeometry.matches(actual.frame, original.frame) else { return nil }
                    return (original.id, actual.frame)
                })
                if !achievedPeers.isEmpty {
                    self.undo = (plan, achievedPeers, Set(achievedPeers.keys))
                    self.canUndo = true
                }
                if let reason = outcome.reason { self.report(reason) }
                else if let reason = prepared.fallbackReason { self.report(reason) }
                else { self.status = "Snapped \(outcome.achieved.count) window(s) with one size request each." }
                guard let anchor = focusCandidate, AXIsProcessTrusted(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == batch.frontmostPID else {
                    self.finishInput(); self.token = nil; return
                }
                access.focusConfirmed(anchor, token: batch) { [weak self] in
                    guard let self, self.token === batch else { return }
                    self.finishInput()
                    self.token = nil
                }
            }
        }
    }

    // An icon pair is an explicit two-window command, independent of automatic companion settings.
    func snapPair(_ request: WindowPairSnapRequest) {
        guard request.isCurrent(after: latestAction), AXIsProcessTrusted() else { return }
        cancel()
        latestAction = request.startedAt
        let batch = WindowLayoutBatchToken(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        token = batch
        watchInput(batch)
        let activity = WindowTabPlacementActivity()
        tabPlacement = activity
        NotificationCenter.default.post(name: WindowTabPlacementActivity.began, object: activity)
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
                if plan != nil { self.onPairLayoutAttempted(request.source, request.target) }
                switch outcome {
                case .applied(let source, let target):
                    guard let plan else { self.finishInput(); self.token = nil; return }
                    self.pairUndo = WindowPairUndoRecord(plan: plan, sourceAfter: source, targetAfter: target)
                    self.canUndo = true
                    self.status = "Paired the two selected windows on the target display and Desktop."
                    // Raise both paired windows in stacking order. Leave the dragged app active,
                    // while ensuring its companion is not left behind the previously frontmost app.
                    WindowPairSnapService.focusAfterPair(companion: target, dragged: source,
                        focus: { window, completion in access.focusConfirmed(window, token: batch, completion: completion) },
                        completion: { [weak self] in
                            guard let self, self.token === batch else { return }
                            self.finishInput()
                        })
                case .stopped(let reason): self.finishInput(); self.token = nil; self.report(reason)
                }
            }
        }
    }

    // Snapshot and execute share one deadline. Only current results can update Undo or learned limits.
    private func adjust(_ snap: WindowLayoutCompletedSnap) {
        pending = nil
        guard enabled, snapMode == .legacy, AXIsProcessTrusted() else { return }
        let requestGeneration = generation
        let batch = WindowLayoutBatchToken(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        token = batch
        watchInput(batch)
        let activity = WindowTabPlacementActivity()
        tabPlacement = activity
        NotificationCenter.default.post(name: WindowTabPlacementActivity.began, object: activity)
        let displays = WindowLayoutDisplay.connected()
        let selection = self.selection
        let maximumWindows = self.maximumWindows
        let grouped = tabSnapExclusions(snap.window)
        let groupMinimums = tabGroupMinimums()
        let logger = self.logger
        let knownConstraints = learnedConstraints
        let cacheLifetime = Self.constraintCacheLifetime
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        let budget = WindowControlBudget(deadline: deadline, canContinue: { !batch.isCancelled })
        reader.queue.async { [weak self, reader] in
            guard !batch.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                DispatchQueue.main.async {
                    guard let self, self.token === batch else { return }
                    self.finishInput()
                    self.token = nil
                }
                return
            }
            let nativeSnapshot = reader.layoutSnapshot(displays: displays, desktop: requestGeneration,
                snap: snap, selection: selection, maximumWindows: maximumWindows, budget: budget, excluding: grouped)
            let snapshot = Self.respectingTabMinimum(nativeSnapshot, minimums: groupMinimums)
            let applicable = Dictionary(uniqueKeysWithValues: snapshot.windows.compactMap { window -> (WindowLayoutIdentity, WindowLayoutSizeConstraint)? in
                guard let record = knownConstraints[window.id], record.scope == window.scope,
                      SidebarPlacementGeometry.matches(record.workArea, snap.request.workArea),
                      ProcessInfo.processInfo.systemUptime - record.recordedAt < cacheLifetime,
                      window.frame.width + 2 >= record.value.minimum.width,
                      window.frame.height + 2 >= record.value.minimum.height,
                      window.frame.width <= record.value.maximum.width + 2,
                      window.frame.height <= record.value.maximum.height + 2 else { return nil }
                return (window.id, record.value)
            })
            let planning: WindowLayoutPlanningResult = ProcessInfo.processInfo.systemUptime < deadline
                ? WindowLayoutPlanner.plan(snapshot: snapshot, anchorID: snap.window, request: snap.request,
                    selection: selection, maximumWindows: maximumWindows, preferredCompanion: snap.preferredCompanion,
                    learned: applicable, achievedFrame: snap.achievedFrame)
                : .rejected("Window preparation took too long; your snap stays in place.")
            var result: WindowLayoutBatchResult?
            var plan: WindowLayoutPlan?
            var learnedUpdates: [WindowLayoutIdentity: WindowLayoutSizeConstraint] = [:]
            var progress: [WindowLayoutIdentity: CGRect]?
            if case .ready(let ready) = planning {
                plan = ready
                logger.notice("Planning anchor \(ready.anchor.id.window.windowID, privacy: .public), peers \(String(describing: ready.peers.map { $0.id.window.windowID }), privacy: .public), targets \(String(describing: ready.frames), privacy: .public)")
                result = Self.execute(ready, reader: reader, displays: displays, batch: batch,
                    deadline: deadline, onLearn: { id, value in learnedUpdates[id] = value },
                    onProgress: { progress = $0 })
            }
            DispatchQueue.main.async {
                guard let self, self.token === batch, requestGeneration == self.generation else { return }
                self.finishInput()
                self.token = nil
                if let plan {
                    for window in plan.windows {
                        guard let value = learnedUpdates[window.id] else { continue }
                        self.learnedConstraints[window.id] = LearnedConstraint(scope: window.scope,
                            workArea: plan.workArea, value: value,
                            recordedAt: ProcessInfo.processInfo.systemUptime)
                    }
                    if self.learnedConstraints.count > Self.maximumCachedConstraints { self.learnedConstraints.removeAll() }
                }
                switch planning {
                case .noPeer: self.status = snap.request.snap?.isCorner == true
                    ? "Corner snaps leave companions untouched unless at least two are selected."
                    : "No other normal window on this display and Desktop."
                case .rejected(let reason): self.report(reason)
                case .ready:
                    guard let plan, let result else { return }
                    switch result {
                    case .applied(let actual):
                        self.undo = (plan, actual, nil)
                        self.canUndo = true
                        self.status = "Arranged \(plan.windows.count) windows around their size limits."
                        self.logger.notice("Adjusted \(plan.peers.count, privacy: .public) peers, display \(plan.scope.displayID, privacy: .public), Desktop \(plan.scope.spaceID, privacy: .public), anchor \(String(describing: plan.anchor.frame), privacy: .public), actual \(String(describing: actual), privacy: .public)")
                    case .stopped(let reason):
                        if plan.snap.isCorner, let progress,
                           plan.windows.contains(where: { window in
                               progress[window.id].map { !SidebarPlacementGeometry.matches($0, window.frame) } == true
                           }) {
                            self.undo = (plan, progress, nil)
                            self.canUndo = true
                        }
                        self.report(reason)
                    }
                }
            }
        }
    }

    // Give the representative the largest known minimum in its group. A hidden tab
    // must not make the planner promise a size it is already known to reject.
    nonisolated static func respectingTabMinimum(_ window: WindowLayoutWindow,
                                                minimums: [SidebarWindowID: CGSize]) -> WindowLayoutWindow {
        guard let minimum = minimums[window.id.window] else { return window }
        return WindowLayoutWindow(id: window.id, scope: window.scope, frame: window.frame,
            minimum: CGSize(width: max(window.minimum.width, minimum.width),
                            height: max(window.minimum.height, minimum.height)),
            minimumReported: window.minimumReported, canMove: window.canMove, canResize: window.canResize,
            hidden: window.hidden, minimized: window.minimized, blocked: window.blocked,
            recency: window.recency, stackOrder: window.stackOrder)
    }

    nonisolated private static func respectingTabMinimum(_ snapshot: WindowLayoutSnapshot,
                                                        minimums: [SidebarWindowID: CGSize]) -> WindowLayoutSnapshot {
        WindowLayoutSnapshot(windows: snapshot.windows.map { respectingTabMinimum($0, minimums: minimums) },
            displays: snapshot.displays, complete: snapshot.complete, desktopGeneration: snapshot.desktopGeneration,
            failureReason: snapshot.failureReason)
    }

    // Bridge pure layout operations directly to native access; the writer receives the executor's exact live snapshot.
    nonisolated private static func execute(_ plan: WindowLayoutPlan, reader: SidebarWindowReader,
                                           displays: [WindowLayoutDisplay], batch: WindowLayoutBatchToken,
                                           deadline: TimeInterval,
                                           onLearn: (WindowLayoutIdentity, WindowLayoutSizeConstraint) -> Void,
                                           onProgress: ([WindowLayoutIdentity: CGRect]) -> Void) -> WindowLayoutBatchResult {
        func canContinue() -> Bool {
            let focused = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return !batch.isCancelled && AXIsProcessTrusted()
                && (focused == batch.frontmostPID || focused == plan.anchor.id.window.pid)
        }
        let budget = WindowControlBudget(deadline: deadline, canContinue: canContinue)
        let access = reader.windowControlAccess
        let byID = Dictionary(uniqueKeysWithValues: plan.windows.map { ($0.id, $0) })
        return WindowLayoutExecutor.apply(plan, canContinue: canContinue,
            read: { id in
                guard let expected = byID[id] else { return nil }
                return access.read(id.window, displays: displays, budget: budget, expected: expected).window
            },
            write: { window, frame, _ in
                let result = access.write(window, frame: frame, workArea: plan.workArea,
                    destination: plan.scope, displays: displays, budget: budget, policy: .sameDisplayAdjustment)
                #if DEBUG
                let logger = Logger(subsystem: "com.mayank.octopus", category: "WindowLayout")
                logger.notice("Writer window \(window.id.window.windowID, privacy: .public), requested \(String(describing: frame), privacy: .public), result \(String(describing: result), privacy: .public)")
                #endif
                return result
            }, deadline: deadline, onLearn: onLearn, onProgress: onProgress)
    }

    func undoAdjustment() {
        if let pairUndo { undoPair(pairUndo); return }
        guard enabled, let undo else { return }
        cancel()
        let batch = WindowLayoutBatchToken(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        token = batch
        watchInput(batch)
        let displays = WindowLayoutDisplay.connected()
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        let canContinue = { !batch.isCancelled && AXIsProcessTrusted()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == batch.frontmostPID }
        let budget = WindowControlBudget(deadline: deadline, canContinue: canContinue)
        reader.queue.async { [weak self, reader] in
            let byID = Dictionary(uniqueKeysWithValues: undo.plan.windows.map { ($0.id, $0) })
            let access = reader.windowControlAccess
            let result = WindowLayoutExecutor.restore(undo.plan, achieved: undo.achieved,
                canContinue: canContinue,
                read: { id in
                    guard let expected = byID[id] else { return nil }
                    return access.read(id.window, displays: displays, budget: budget, expected: expected).window
                },
                write: { window, frame, _ in
                    access.write(window, frame: frame, workArea: undo.plan.workArea,
                        destination: undo.plan.scope, displays: displays, budget: budget, policy: .sameDisplayAdjustment)
                }, deadline: deadline, participants: undo.participants)
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

    // Pair Undo restores both original visible scopes; edge-layout Undo restores every changed frame.
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
        if let tabPlacement {
            NotificationCenter.default.post(name: WindowTabPlacementActivity.ended, object: tabPlacement)
            self.tabPlacement = nil
        }
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
        snapPreparation?.cancel()
        snapPreparation = nil
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
