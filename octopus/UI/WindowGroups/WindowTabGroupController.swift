import AppKit

@MainActor
final class WindowTabGroupController {
    struct Preparation {
        let source: WindowTabMember
        let members: [WindowTabMember]
        let target: SidebarWindowID
        let groupID: UUID?
        let frame: CGRect
        let scope: WindowLayoutScope
        let revision: Int
    }

    private lazy var reader = SidebarWindowReader(onChange: { [weak self] in
        Task { @MainActor in self?.scheduleRefresh() }
    })
    private let drag = WindowGroupDragMonitor()
    private let keyboard = WindowTabGroupKeyboardMonitor()
    private let feedback = WindowPlacementFeedback()
    private var groups: [UUID: WindowTabGroup] = [:]
    private var panels: [UUID: WindowTabStripPanel] = [:]
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var hoverToken: WindowLayoutBatchToken?
    private var operation: WindowLayoutBatchToken?
    private var sidebarFocus: SidebarPendingAction?
    var focusUsingSidebar: ((SidebarWindowID, @escaping (Bool) -> Void) -> SidebarPendingAction?)?
    private var prepared: Preparation?
    private var refreshWork: DispatchWorkItem?
    private var refreshing = false
    private var refreshToken: WindowLayoutBatchToken?
    private var refreshAgain = false
    private var revision = 0
    private var running = false
    private var nativePlacements: Set<UUID> = []
    private var movingGroup: UUID?

    func snapExclusions(for source: SidebarWindowID) -> Set<SidebarWindowID> {
        groups.values.reduce(into: []) { $0.formUnion($1.snapExclusions(for: source)) }
    }

    var groupMinimums: [SidebarWindowID: CGSize] {
        Dictionary(uniqueKeysWithValues: groups.values.flatMap { group in
            group.members.map { ($0.window.id.window, group.minimum) }
        })
    }

    func separateForSideDrop(source: SidebarWindowID, target: SidebarWindowID) {
        cancelOperation()
        cancelHover()
        for window in [source, target] {
            if let identity = group(containing: window)?.members.first(where: { $0.window.id.window == window })?.window.id {
                removeMembership(identity)
            }
        }
        updateObservation()
        scheduleRefresh()
    }

    func start() {
        guard !running else { return }
        running = true
        keyboard.sourceWindow = { [weak self] in
            guard let self, self.running, WindowLayoutSettings.tabGroupingEnabled(),
                  NSEvent.pressedMouseButtons & 1 == 0,
                  let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let window = WindowGroupDragMonitor.frontmostWindow(pid: pid),
                  self.group(containing: window) != nil else { return nil }
            return window
        }
        keyboard.onSwitch = { [weak self] window, direction in self?.cycle(from: window, direction: direction) }
        drag.enabled = { [weak self] in self?.running == true && WindowLayoutSettings.tabGroupingEnabled() }
        drag.excludedWindows = { [weak self] source in
            Set(self?.group(containing: source)?.members.map(\.window.id.window) ?? [source])
        }
        drag.prepare = { [weak self] source, target, original, completion in
            self?.prepare(source: source, target: target, original: original, completion: completion)
        }
        drag.commit = { [weak self] source, target in self?.commit(source: source, target: target) }
        drag.onCancel = { [weak self] in self?.cancelHover() }
        drag.onInput = { [weak self] in
            self?.cancelRefresh()
            self?.cancelOperation()
            self?.panels.values.forEach { $0.cancelDrag() }
            self?.scheduleRefresh()
        }
        drag.onRelease = { [weak self] in self?.scheduleRefresh() }
        drag.onGeometryChange = { [weak self] in self?.scheduleRefresh() }
        drag.start()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: WindowTabPlacementActivity.began, object: nil, queue: .main) { [weak self] note in
            guard let activity = note.object as? WindowTabPlacementActivity else { return }
            MainActor.assumeIsolated {
                self?.cancelRefresh()
                self?.cancelOperation()
                _ = self?.nativePlacements.insert(activity.id)
            }
        })
        observers.append(center.addObserver(forName: WindowTabPlacementActivity.ended, object: nil, queue: .main) { [weak self] note in
            guard let activity = note.object as? WindowTabPlacementActivity else { return }
            MainActor.assumeIsolated {
                self?.nativePlacements.remove(activity.id)
                self?.scheduleRefresh()
            }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dissolveAll() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.drag.cancel()
                    self?.cancelOperation()
                    self?.panels.values.forEach { $0.orderOut(nil) }
                    self?.scheduleRefresh()
                }
            })
        }
    }

    private func group(containing window: SidebarWindowID) -> WindowTabGroup? {
        groups.values.first { $0.members.contains { $0.window.id.window == window } }
    }

    private func cancelHover() {
        hoverToken?.cancel()
        hoverToken = nil
        prepared = nil
    }

    private func cancelOperation() {
        sidebarFocus?.cancel()
        sidebarFocus = nil
        operation?.cancel()
        operation = nil
        movingGroup = nil
        revision += 1
    }

    private func cancelRefresh() {
        refreshToken?.cancel()
        refreshToken = nil
        refreshWork?.cancel()
        refreshWork = nil
    }

    private func beginOperation(cancelLayouts: Bool = true) -> WindowLayoutBatchToken {
        cancelRefresh()
        cancelOperation()
        cancelHover()
        if cancelLayouts {
            NotificationCenter.default.post(name: WindowLayoutController.userActionNotification,
                object: ProcessInfo.processInfo.systemUptime)
        }
        let token = WindowLayoutBatchToken(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        operation = token
        return token
    }

    private func budget(for token: WindowLayoutBatchToken, seconds: TimeInterval = 4) -> WindowControlBudget {
        WindowControlBudget(deadline: ProcessInfo.processInfo.systemUptime + seconds, canContinue: {
            !token.isCancelled && NSWorkspace.shared.frontmostApplication?.processIdentifier == token.frontmostPID
        })
    }

    private func prepare(source: SidebarWindowID, target: SidebarWindowID, original: CGRect,
                         completion: @escaping (CGRect?) -> Void) {
        cancelHover()
        let token = WindowLayoutBatchToken(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        hoverToken = token
        readPreparation(source: source, target: target, original: original, token: token) { [weak self] result in
            guard let self, self.hoverToken === token, !token.isCancelled else { completion(nil); return }
            self.prepared = result
            completion(result?.frame)
        }
    }

    @discardableResult func prepareTabs(source: SidebarWindowID, target: SidebarWindowID,
                                       completion: @escaping (Preparation?) -> Void) -> WindowLayoutBatchToken {
        let token = WindowLayoutBatchToken(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        readPreparation(source: source, target: target, original: nil, token: token, completion: completion)
        return token
    }

    private func readPreparation(source: SidebarWindowID, target: SidebarWindowID, original: CGRect?,
                                 token: WindowLayoutBatchToken, completion: @escaping (Preparation?) -> Void) {
        guard running, WindowLayoutSettings.tabGroupingEnabled(), source != target else { completion(nil); return }
        let targetGroup = group(containing: target)
        guard targetGroup?.members.contains(where: { $0.window.id.window == source }) != true else {
            completion(nil); return
        }
        let previousSource = group(containing: source)?.members.first { $0.window.id.window == source }
        let previousTarget = targetGroup?.members.first { $0.window.id.window == target }
        let nativeBudget = budget(for: token, seconds: 1)
        let displays = WindowLayoutDisplay.connected()
        let currentRevision = revision
        reader.queue.async { [weak self, reader] in
            let access = reader.windowControlAccess
            var drop: Preparation?
            if let a = access.read(source, displays: displays, budget: nativeBudget).window,
               let b = access.read(target, displays: displays, budget: nativeBudget,
                expected: previousTarget?.window, forFocus: targetGroup != nil).window,
               a.eligible, b.eligible, a.scope == b.scope,
               let display = displays.first(where: { $0.id == b.scope.displayID }) {
                var members: [WindowTabMember] = []
                let identities = targetGroup?.members.map(\.window.id) ?? [b.id]
                for identity in identities {
                    let old = targetGroup?.members.first { $0.window.id == identity }
                    let candidate = identity == b.id ? b : access.read(identity.window, displays: displays,
                        budget: nativeBudget, expected: old?.window, forFocus: true).window
                    guard nativeBudget.isCurrent,
                          let live = candidate,
                          live.id == identity, live.eligible, live.scope == b.scope else { members.removeAll(); break }
                    members.append(WindowTabMember(window: live, originalFrame: old?.originalFrame ?? live.frame,
                        title: old?.title ?? access.tabTitle(identity, budget: nativeBudget) ?? ""))
                }
                let frame = targetGroup == nil ? WindowTabGeometry.groupFrame(target: b.frame, workArea: display.workArea) : b.frame
                if !members.isEmpty, WindowTabGeometry.fits(frame, windows: members.map(\.window) + [a], scope: b.scope) {
                    let member = WindowTabMember(window: a, originalFrame: previousSource?.originalFrame ?? original ?? a.frame,
                        title: access.tabTitle(a.id, budget: nativeBudget) ?? previousSource?.title ?? "")
                    drop = Preparation(source: member, members: members, target: target, groupID: targetGroup?.id,
                        frame: frame, scope: b.scope, revision: currentRevision)
                }
            }
            let result = drop
            DispatchQueue.main.async {
                guard let self, !token.isCancelled,
                      self.running, WindowLayoutSettings.tabGroupingEnabled(), self.revision == currentRevision else { completion(nil); return }
                completion(result)
            }
        }
    }

    private func commit(source: SidebarWindowID, target: SidebarWindowID) {
        guard let drop = prepared, drop.source.window.id.window == source, drop.target == target else { return }
        commitTabs(drop)
    }

    func commitTabs(_ drop: Preparation) {
        guard drop.revision == revision, running, WindowLayoutSettings.tabGroupingEnabled() else {
            feedback.showFeedback("The tab-group preview changed. Drag again.")
            return
        }
        let source = drop.source.window.id.window
        let token = beginOperation()
        let nativeBudget = budget(for: token)
        let displays = WindowLayoutDisplay.connected()
        reader.queue.async { [weak self, reader] in
            let access = reader.windowControlAccess
            // The source naturally moves after hover. Its identity and scope are fixed;
            // refresh only its frame on release, while the target must still match the preview.
            var outcome = WindowTabAlignmentResult(reason: "The hovered window changed. Drag again.")
            if let sourceNow = access.read(source, displays: displays, budget: nativeBudget, expected: drop.source.window).window,
               sourceNow.id == drop.source.window.id, sourceNow.scope == drop.scope {
                outcome = WindowTabGroupService.align(drop.members.map(\.window) + [sourceNow], to: drop.frame,
                    scope: drop.scope, displays: displays, access: access, budget: nativeBudget)
            }
            let result = outcome
            DispatchQueue.main.async {
                guard let self, self.operation === token, !token.isCancelled else { return }
                guard result.reason == nil, result.windows.count == drop.members.count + 1 else {
                    self.finish(token, reason: result.reason); return
                }
                self.removeMembership(drop.source.window.id)
                let id = drop.groupID ?? UUID()
                var members = drop.members + [drop.source]
                for index in members.indices { members[index].window = result.windows[index] }
                self.groups[id] = WindowTabGroup(id: id, members: members, selected: drop.source.window.id,
                    frame: drop.frame, scope: drop.scope)
                if let group = self.groups[id] { self.showPanel(group) }
                self.revision += 1
                self.updateObservation()
                guard let selected = result.windows.last else { self.finish(token); return }
                self.focus(selected, token: token)
            }
        }
    }

    private func select(_ identity: WindowLayoutIdentity, closing: Bool = false) {
        guard let group = group(containing: identity.window),
              let member = group.members.first(where: { $0.window.id == identity }) else { return }
        let token = beginOperation()
        let nativeBudget = budget(for: token)
        let displays = WindowLayoutDisplay.connected()
        reader.queue.async { [weak self, reader] in
            let access = reader.windowControlAccess
            let selected = WindowTabGroupService.selection(member.window, scope: group.scope,
                canContinue: { nativeBudget.isCurrent }, read: {
                    access.read($0.id.window, displays: displays, budget: nativeBudget, expected: $0, forFocus: true).window
                })
            DispatchQueue.main.async {
                guard let self, self.operation === token, !token.isCancelled else { return }
                guard let selected, var current = self.groups[group.id],
                      let index = current.members.firstIndex(where: { $0.window.id == identity }) else {
                    self.finish(token, reason: "This tab is no longer available on this Desktop."); return
                }
                current.members[index].window = selected
                current.selected = identity
                current.frame = selected.frame
                self.groups[group.id] = current
                self.showPanel(current)
                self.focus(selected, token: token, closing: closing)
            }
        }
    }

    private func cycle(from window: SidebarWindowID, direction: Int) {
        guard running, operation == nil, nativePlacements.isEmpty,
              WindowLayoutSettings.tabGroupingEnabled(),
              let group = group(containing: window),
              let member = group.members.first(where: { $0.window.id.window == window }),
              let next = group.neighbour(of: member.window.id, direction: direction),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else { return }
        let token = beginOperation()
        let displays = WindowLayoutDisplay.connected()
        let nativeBudget = budget(for: token, seconds: 1)
        reader.queue.async { [weak self, reader] in
            let access = reader.windowControlAccess
            let current = access.read(window, displays: displays, budget: nativeBudget, expected: member.window, forFocus: true).window
            let ready = current?.eligible == true && current?.scope == group.scope
                && access.focusedWindowID(pid: window.pid, budget: nativeBudget) == window
            DispatchQueue.main.async {
                guard let self, self.operation === token, !token.isCancelled else { return }
                guard ready, nativeBudget.isCurrent else { self.finish(token); return }
                self.select(next) // Reuse the exact-window sidebar focus path.
            }
        }
    }

    private func beginGroupMove(_ id: UUID) -> Bool {
        guard running, WindowLayoutSettings.tabGroupingEnabled(), nativePlacements.isEmpty,
              groups[id]?.active?.window.eligible == true else { return false }
        cancelRefresh()
        cancelOperation()
        drag.cancel()
        NotificationCenter.default.post(name: WindowLayoutController.userActionNotification,
            object: ProcessInfo.processInfo.systemUptime)
        return true
    }

    private func moveGroup(_ id: UUID, from original: CGRect, to frame: CGRect) {
        guard running, WindowLayoutSettings.tabGroupingEnabled(), NSEvent.pressedMouseButtons & 1 == 0,
              let group = groups[id] else { scheduleRefresh(); return }
        let token = beginOperation()
        movingGroup = id
        let currentRevision = revision
        let displays = WindowLayoutDisplay.connected()
        let originalBudget = budget(for: token)
        let nativeBudget = WindowControlBudget(deadline: originalBudget.deadline, canContinue: {
            originalBudget.isCurrent && NSEvent.pressedMouseButtons & 1 == 0
        })
        reader.queue.async { [weak self, reader] in
            let access = reader.windowControlAccess
            var windows: [WindowLayoutWindow] = []
            for member in group.members {
                guard nativeBudget.isCurrent,
                      let live = access.read(member.window.id.window, displays: displays, budget: nativeBudget,
                        expected: member.window, forFocus: true).window,
                      live.id == member.window.id, live.eligible, live.scope == group.scope else { break }
                windows.append(live)
            }
            let result = windows.count == group.members.count
                ? WindowTabGroupService.move(windows, selected: group.selected, from: original, to: frame,
                    scope: group.scope, displays: displays, access: access, budget: nativeBudget)
                : WindowTabAlignmentResult(reason: "The group changed during the drag; remaining windows were left untouched.")
            DispatchQueue.main.async {
                guard let self, self.operation === token, !token.isCancelled, self.revision == currentRevision else { return }
                self.movingGroup = nil
                if let reason = result.reason {
                    if result.placementFailed {
                        self.groups.removeValue(forKey: id)
                        self.panels.removeValue(forKey: id)?.close()
                        self.revision += 1
                        self.updateObservation()
                    }
                    self.finish(token, reason: reason, refresh: false)
                    return
                }
                guard var current = self.groups[id], result.windows.count == current.members.count,
                      let active = result.windows.first(where: { $0.id == group.selected }) else { self.finish(token); return }
                for index in current.members.indices { current.members[index].window = result.windows[index] }
                current.frame = active.frame
                self.groups[id] = current
                self.showPanel(current)
                self.focus(active, token: token)
            }
        }
    }

    private func focus(_ window: WindowLayoutWindow, token: WindowLayoutBatchToken, closing: Bool = false) {
        guard operation === token, !token.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == token.frontmostPID else { finish(token); return }
        guard let focusUsingSidebar else {
            finish(token, reason: "Window focusing is unavailable.")
            return
        }
        sidebarFocus = focusUsingSidebar(window.id.window) { [weak self] raised in
            guard let self, self.operation === token, !token.isCancelled else { return }
            self.sidebarFocus = nil
            guard raised else {
                self.finish(token, reason: "The sidebar could not bring this window to the front.")
                return
            }
            let displays = WindowLayoutDisplay.connected()
            let members = Set(self.group(containing: window.id.window)?.members.map(\.window.id.window) ?? [window.id.window])
            let nativeBudget = WindowControlBudget(deadline: ProcessInfo.processInfo.systemUptime + 1, canContinue: {
                !token.isCancelled && NSWorkspace.shared.frontmostApplication?.processIdentifier == window.id.window.pid
            })
            self.reader.queue.async { [weak self, reader = self.reader] in
                let access = reader.windowControlAccess
                let focused = WindowTabGroupService.confirmFocus(canContinue: { nativeBudget.isCurrent }, readConfirmed: {
                    access.focusedWindowID(pid: window.id.window.pid, budget: nativeBudget) == window.id.window
                        && access.tabIsInFront(window.id.window, members: members, budget: nativeBudget) == true
                }, wait: { Thread.sleep(forTimeInterval: 0.025) })
                let closed = closing && focused && access.closeTab(window, displays: displays, budget: nativeBudget)
                DispatchQueue.main.async {
                    // Leave membership intact until destruction is confirmed; canceling a save
                    // dialog keeps the window and its tab. No force-close or app termination.
                    self?.finish(token, reason: closing
                        ? (closed ? nil : "This app could not close the selected window.")
                        : (focused ? nil : "The app became active, but this window could not come to the front."))
                }
            }
        }
    }

    private func detach(_ identity: WindowLayoutIdentity, at point: CGPoint?) {
        guard let group = group(containing: identity.window),
              let member = group.members.first(where: { $0.window.id == identity }) else { return }
        let token = beginOperation()
        let displays = WindowLayoutDisplay.connected()
        let nativeBudget = budget(for: token)
        reader.queue.async { [weak self, reader] in
            let access = reader.windowControlAccess
            var actual: WindowLayoutWindow?
            if let current = access.read(identity.window, displays: displays, budget: nativeBudget, expected: member.window, forFocus: true).window,
               current.id == identity, current.eligible, current.scope == group.scope,
               let display = displays.first(where: { $0.id == current.scope.displayID }),
               point == nil || display.frame.contains(point!) {
                let frame = WindowTabGeometry.detachedFrame(original: member.originalFrame, at: point, workArea: display.workArea)
                if case .placed(let achieved, _) = access.write(current, frame: frame, workArea: display.workArea,
                    destination: current.scope, displays: displays, budget: nativeBudget, policy: .preparedSnap, allowCovered: true),
                   let live = access.read(identity.window, displays: displays, budget: nativeBudget, expected: current, forFocus: true).window,
                   live.id == identity, live.eligible, live.scope == current.scope,
                   display.workArea.contains(live.frame), SidebarPlacementGeometry.matches(live.frame, achieved) { actual = live }
            }
            let result = actual
            DispatchQueue.main.async {
                guard let self, self.operation === token, !token.isCancelled else { return }
                guard let result else {
                    self.finish(token, reason: "The tab could not move out. Drop it on the same display, away from the strip."); return
                }
                self.removeMembership(identity)
                self.updateObservation()
                self.focus(result, token: token)
            }
        }
    }

    private func finish(_ token: WindowLayoutBatchToken, reason: String? = nil, refresh: Bool = true) {
        guard operation === token else { return }
        operation = nil
        movingGroup = nil
        if let reason { feedback.showFeedback(reason) }
        if refresh { scheduleRefresh() }
        else { refreshAgain = false; refreshPanelGeometry() }
    }

    private func removeMembership(_ identity: WindowLayoutIdentity) {
        guard var group = group(containing: identity.window) else { return }
        group.remove(identity)
        revision += 1
        if group.members.count < 2 {
            groups.removeValue(forKey: group.id)
            panels.removeValue(forKey: group.id)?.close()
        } else { groups[group.id] = group }
    }

    private func updateObservation() {
        if groups.isEmpty { keyboard.stop() }
        else if !keyboard.start() { feedback.showFeedback("Tab shortcuts are unavailable. Check Stack King's Accessibility permission.") }
        let identities = groups.values.flatMap { $0.members.map(\.window.id) }
        let nativeBudget = WindowControlBudget(deadline: ProcessInfo.processInfo.systemUptime + 2, canContinue: { true })
        reader.queue.async { [reader] in reader.observeTabWindows(identities, budget: nativeBudget) }
    }

    private func scheduleRefresh() {
        guard running, !groups.isEmpty else { return }
        guard AXIsProcessTrusted() else { dissolveAll(); return }
        if panels.values.contains(where: { $0.isDraggingGroup }) { refreshAgain = true; return }
        // Read only CG geometry here, so the strip follows snaps even while AX work is pending.
        refreshPanelGeometry()
        if operation != nil || refreshing || !nativePlacements.isEmpty { refreshAgain = true; return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            refreshAgain = true
            return
        }
        guard refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.refreshNative() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func refreshPanelGeometry() {
        for group in groups.values {
            guard group.id != movingGroup, let active = group.active, active.window.eligible,
                  let surface = WindowGroupDragMonitor.surface(id: active.window.id.window) else { continue }
            var displayed = group
            displayed.frame = surface.frame
            showPanel(displayed)
        }
    }

    private func refreshNative() {
        refreshWork = nil
        guard running, !groups.isEmpty, operation == nil, nativePlacements.isEmpty else { return }
        guard NSEvent.pressedMouseButtons & 1 == 0 else { scheduleRefresh(); return }
        refreshing = true
        refreshAgain = false
        let saved = Array(groups.values)
        let currentRevision = revision
        let displays = WindowLayoutDisplay.connected()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let refresh = WindowLayoutBatchToken(frontmostPID: nil)
        refreshToken = refresh
        let nativeBudget = WindowControlBudget(deadline: ProcessInfo.processInfo.systemUptime + 2, canContinue: { !refresh.isCancelled })
        reader.queue.async { [weak self, reader] in
            let access = reader.windowControlAccess
            var live: [WindowLayoutIdentity: WindowLayoutWindow] = [:]
            var missing: [WindowLayoutIdentity] = []
            var titles: [WindowLayoutIdentity: String] = [:]
            for member in saved.flatMap(\.members) {
                guard nativeBudget.isCurrent else { break }
                switch access.tabPresence(member.window.id, budget: nativeBudget) {
                case .missing, .separated: missing.append(member.window.id)
                case .present:
                    if let window = access.read(member.window.id.window, displays: displays, budget: nativeBudget,
                        expected: member.window, forFocus: true).window {
                        live[member.window.id] = window
                        titles[member.window.id] = access.tabTitle(member.window.id, budget: nativeBudget)
                    }
                case .unknown: break
                }
            }
            let focused = foreground.flatMap { access.focusedWindowID(pid: $0, budget: nativeBudget) }
            let windows = live, absent = missing, labels = titles
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                if self.refreshToken === refresh { self.refreshToken = nil }
                guard !refresh.isCancelled, self.running, self.revision == currentRevision,
                      self.operation == nil, self.nativePlacements.isEmpty, NSEvent.pressedMouseButtons & 1 == 0 else {
                    self.scheduleRefresh(); return
                }
                for identity in absent { self.removeMembership(identity) }
                var sync: UUID?
                var membershipChanged = !absent.isEmpty
                for id in Array(self.groups.keys) {
                    guard var group = self.groups[id] else { continue }
                    // An explicit external Desktop/display move separates just that window.
                    let departed = group.members.compactMap { member -> WindowLayoutIdentity? in
                        guard let current = windows[member.window.id], current.scope != group.scope else { return nil }
                        return member.window.id
                    }
                    for identity in departed { self.removeMembership(identity) }
                    membershipChanged = membershipChanged || !departed.isEmpty
                    guard let retained = self.groups[id] else { continue }
                    group = retained
                    for index in group.members.indices {
                        let identity = group.members[index].window.id
                        if let window = windows[identity] { group.members[index].window = window }
                        if let title = labels[identity] { group.members[index].title = title }
                    }
                    if let selected = group.members.first(where: { $0.window.id.window == focused }),
                       windows[selected.window.id]?.eligible == true { group.selected = selected.window.id }
                    guard let active = group.active, let actual = windows[active.window.id], actual.eligible else {
                        self.groups[id] = group
                        self.panels[id]?.orderOut(nil)
                        continue
                    }
                    group.frame = actual.frame
                    self.groups[id] = group
                    self.showPanel(group)
                    if sync == nil, NSEvent.pressedMouseButtons & 1 == 0,
                       group.members.allSatisfy({ windows[$0.window.id]?.eligible == true }),
                       group.members.contains(where: { !SidebarPlacementGeometry.matches($0.window.frame, group.frame) }) { sync = id }
                }
                if membershipChanged { self.updateObservation() }
                if let sync { self.synchronize(sync) }
                else if self.refreshAgain { self.scheduleRefresh() }
            }
        }
    }

    private func synchronize(_ id: UUID) {
        guard let group = groups[id], group.members.count > 1, operation == nil,
              NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let token = beginOperation(cancelLayouts: false)
        let originalBudget = budget(for: token)
        let nativeBudget = WindowControlBudget(deadline: originalBudget.deadline, canContinue: {
            originalBudget.isCurrent && NSEvent.pressedMouseButtons & 1 == 0
        })
        let displays = WindowLayoutDisplay.connected()
        reader.queue.async { [weak self, reader] in
            let result = WindowTabGroupService.align(group.members.map(\.window), to: group.frame, scope: group.scope,
                displays: displays, access: reader.windowControlAccess, budget: nativeBudget)
            DispatchQueue.main.async {
                guard let self, self.operation === token, !token.isCancelled else { return }
                guard NSEvent.pressedMouseButtons & 1 == 0,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == token.frontmostPID else {
                    self.finish(token); return
                }
                if let reason = result.reason {
                    guard result.placementFailed else {
                        // Stale reads and cancellations do not mean an app refused a resize.
                        // Wait for the next native change instead of dissolving or retrying.
                        self.finish(token, reason: reason, refresh: false)
                        return
                    }
                    // A refused resize cannot become an endless notification/write loop.
                    // Leave every real window accessible and dissolve this group.
                    self.groups.removeValue(forKey: id)
                    self.panels.removeValue(forKey: id)?.close()
                    self.revision += 1
                    self.updateObservation()
                    self.finish(token, reason: reason)
                    return
                }
                if var current = self.groups[id] {
                    for index in current.members.indices { current.members[index].window = result.windows[index] }
                    self.groups[id] = current
                }
                self.finish(token)
            }
        }
    }

    private func showPanel(_ group: WindowTabGroup) {
        guard let display = WindowLayoutDisplay.connected().first(where: { $0.id == group.scope.displayID }) else { return }
        let panel: WindowTabStripPanel
        if let existing = panels[group.id] { panel = existing }
        else {
            panel = WindowTabStripPanel(groupID: group.id)
            panel.onSelect = { [weak self] in self?.select($0) }
            panel.onDetach = { [weak self] in self?.detach($0, at: $1) }
            panel.onClose = { [weak self] in self?.select($0, closing: true) }
            panel.onMoveStart = { [weak self] in self?.beginGroupMove(group.id) == true }
            panel.onMove = { [weak self] original, frame in self?.moveGroup(group.id, from: original, to: frame) }
            panel.onMoveCancel = { [weak self] in self?.scheduleRefresh() }
            panels[group.id] = panel
        }
        panel.show(group, workArea: display.workArea)
    }

    private func applySettings() {
        if !WindowLayoutSettings.tabGroupingEnabled() { dissolveAll() }
    }

    private func dissolveAll() {
        keyboard.stop()
        drag.cancel()
        cancelOperation()
        refreshWork?.cancel()
        refreshWork = nil
        refreshToken?.cancel()
        refreshToken = nil
        groups.removeAll()
        panels.values.forEach { $0.cancelDrag(); $0.close() }
        panels.removeAll()
        nativePlacements.removeAll()
        reader.queue.async { [reader] in reader.removeObservers() }
    }

    func stop() {
        running = false
        drag.stop()
        dissolveAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        workspaceObservers.removeAll()
        feedback.stop()
    }
}
