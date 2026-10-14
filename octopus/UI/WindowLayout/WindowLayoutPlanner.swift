import AppKit

enum WindowLayoutPlanner {
    // Both requested halves must fit before either app receives a resize command.
    static func pair(source: WindowLayoutWindow, target: WindowLayoutWindow, direction: PairDropDirection,
                     display: WindowLayoutDisplay) -> WindowPairSnapPlan? {
        guard source.id.window != target.id.window, source.eligible, target.eligible,
              target.scope.displayID == display.id, SidebarPlacementGeometry.isValid(display.workArea) else { return nil }
        // oppositeHalf uses AX coordinates; applying the opposite direction yields the chosen half.
        guard let sourceFrame = oppositeHalf(direction.opposite.snap, in: display.workArea),
              let targetFrame = oppositeHalf(direction.snap, in: display.workArea) else { return nil }
        for (window, frame) in [(source, sourceFrame), (target, targetFrame)] {
            guard window.minimum.width.isFinite, window.minimum.height.isFinite,
                  window.minimum.width >= 0, window.minimum.height >= 0,
                  frame.width >= max(window.minimum.width, WindowLayoutSettings.readabilityMinimum.width),
                  frame.height >= max(window.minimum.height, WindowLayoutSettings.readabilityMinimum.height) else { return nil }
        }
        return WindowPairSnapPlan(source: source, target: target, destination: target.scope,
            workArea: display.workArea, sourceFrame: sourceFrame, targetFrame: targetFrame)
    }

    // Only selected candidates incur Accessibility metadata reads. Frames are still read live.
    static func snapshot(anchor: WindowLayoutWindow, candidates: [WindowLayoutCandidate],
                         displays: [WindowLayoutDisplay], desktop: Int, selection: WindowLayoutSelection,
                         maximumWindows: Int = WindowLayoutSettings.defaultMaximumWindows,
                         preferredCompanion: SidebarWindowID? = nil,
                         destination: WindowLayoutScope? = nil,
                         read: (WindowLayoutCandidate) -> WindowLayoutCandidateResolution) -> WindowLayoutSnapshot {
        let preferred = selection == .allNormal ? preferredCompanion : nil
        let ordered = candidates.sorted { a, b in
            if (a.window == preferred) != (b.window == preferred) { return a.window == preferred }
            if a.recency != b.recency { return a.recency > b.recency }
            if a.stackOrder != b.stackOrder { return a.stackOrder < b.stackOrder }
            return a.window.windowID < b.window.windowID
        }
        let limit = WindowLayoutSettings.normalizedMaximumWindows(maximumWindows)
        var windows = [anchor]
        var complete = true
        for candidate in ordered where candidate.window != anchor.id.window {
            let resolution = read(candidate)
            if case .excluded = resolution { continue }
            guard case .window(let window) = resolution, window.scope == (destination ?? anchor.scope) else {
                complete = false; break
            }
            guard window.visible, !window.blocked else { continue }
            if selection == .allNormal, !window.eligible { continue }
            windows.append(window)
            // The cap is a selection limit, not a reason to reject a busy Desktop.
            // Do not read older windows once the selected group is complete.
            if selection == .mostRecent || windows.count == limit { break }
        }
        return WindowLayoutSnapshot(windows: windows, displays: displays, complete: complete, desktopGeneration: desktop)
    }

    // AX coordinates grow downward: the top half starts at the smaller Y.
    static func oppositeHalf(_ snap: SidebarSnapTarget, in area: CGRect) -> CGRect? {
        switch snap {
        case .left: return CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        case .right: return CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        case .top: return CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
        case .bottom: return CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
        case .maximize, .topLeft, .topRight, .bottomLeft, .bottomRight: return nil
        }
    }

    // Validate the complete selected set before mutation. Allocation includes the snapped window so
    // its dividing line can move only when a reported or recently observed app bound requires it.
    static func plan(snapshot: WindowLayoutSnapshot, anchorID: SidebarWindowID,
                     request: SidebarPlacementRequest, selection: WindowLayoutSelection = .mostRecent,
                     maximumWindows: Int = WindowLayoutSettings.defaultMaximumWindows,
                     preferredCompanion: SidebarWindowID? = nil,
                     learned: [WindowLayoutIdentity: WindowLayoutSizeConstraint] = [:],
                     achievedFrame: CGRect? = nil,
                     preparingFor destination: WindowLayoutScope? = nil) -> WindowLayoutPlanningResult {
        if !snapshot.complete { return .rejected(snapshot.failureReason ?? "An open window could not be verified. Your snap stays in place.") }
        guard snapshot.complete, Set(snapshot.windows.map { $0.id.window }).count == snapshot.windows.count,
              let snap = request.snap,
              let anchor = snapshot.windows.first(where: { $0.id.window == anchorID }), anchor.eligible,
              let display = snapshot.displays.first(where: { $0.id == (destination ?? anchor.scope).displayID }),
              SidebarPlacementGeometry.matches(display.workArea, request.workArea),
              destination != nil || SidebarPlacementGeometry.matches(anchor.frame, achievedFrame ?? request.frame) else {
            return .rejected("The snapped window's display or Desktop could not be verified.")
        }
        let peers = snapshot.windows(in: destination ?? anchor.scope).filter {
            $0.id != anchor.id && $0.visible && !$0.blocked && (selection != .allNormal || $0.eligible)
        }
        let preferred = selection == .allNormal ? preferredCompanion : nil
        // Unobserved startup history falls back to the frontmost CG surface, never app enumeration order.
        let ordered = peers.sorted { a, b in
            if (a.id.window == preferred) != (b.id.window == preferred) { return a.id.window == preferred }
            if a.recency != b.recency { return a.recency > b.recency }
            if a.stackOrder != b.stackOrder { return a.stackOrder < b.stackOrder }
            return a.id.window.windowID < b.id.window.windowID
        }
        let limit = WindowLayoutSettings.normalizedMaximumWindows(maximumWindows)
        let selected = Array(ordered.prefix(selection == .mostRecent ? 1 : limit - 1))
        // One selected companion stays untouched. Recent mode therefore never rearranges corners.
        if snap.isCorner && selected.count < 2 { return .noPeer }
        guard !selected.isEmpty else { return .noPeer }
        guard selected.count <= 32, Set(selected.map(\.id)).count == selected.count else {
            return .rejected("The window list could not be arranged safely.")
        }
        for peer in selected {
            guard peer.eligible else { return .rejected("An open window has a fixed size or position.") }
            guard SidebarPlacementGeometry.isValid(peer.frame), peer.minimum.width.isFinite,
                  peer.minimum.height.isFinite, peer.minimum.width >= 0, peer.minimum.height >= 0 else {
                return .rejected("An open window's size could not be verified.")
            }
        }
        let windows = [anchor] + selected
        var constraints = Dictionary(uniqueKeysWithValues: windows.map { window in
            (window.id, destination != nil
                ? WindowLayoutSizeConstraint.reported(for: window, workArea: request.workArea)
                : WindowLayoutSizeConstraint.initial(for: window, workArea: request.workArea, learned: learned[window.id]))
        })
        if destination == nil && (snap.isCorner || !SidebarPlacementGeometry.matches(anchor.frame, request.frame)) {
            guard request.workArea.contains(anchor.frame),
                  SidebarPlacementGeometry.matches(anchor.frame,
                    SidebarPlacementGeometry.snapFrame(snap, size: anchor.frame.size, inAX: request.workArea)),
                  let initial = constraints[anchor.id],
                  let observed = initial.observing(requested: request.frame, achieved: anchor.frame) else {
                return .rejected("The app could not keep the window at the chosen snap edge within this display.")
            }
            constraints[anchor.id] = observed
        }
        guard let allocation = WindowLayoutAllocator.allocate(workArea: request.workArea, snap: snap,
            scale: display.scale, anchor: anchor.id, peers: selected.map(\.id), constraints: constraints) else {
            return .rejected("These windows cannot fit together on this display without overlapping.")
        }
        return .ready(WindowLayoutPlan(scope: destination ?? anchor.scope, desktopGeneration: snapshot.desktopGeneration,
            workArea: request.workArea, snap: snap, scale: display.scale,
            anchor: anchor, peers: selected, constraints: constraints, frames: allocation))
    }

    // A companion failure cannot block the user's own snap. This fallback is shown before release.
    static func preparedPlan(snapshot: WindowLayoutSnapshot?, anchor: WindowLayoutWindow,
                             request: SidebarPlacementRequest, destination: WindowLayoutScope,
                             display: WindowLayoutDisplay, settings: WindowSnapSettings,
                             generation: Int, preferredCompanion: SidebarWindowID? = nil)
                             -> (plan: WindowLayoutPlan, fallbackReason: String?)? {
        guard let single = singleSnap(anchor: anchor, request: request, destination: destination,
                                      display: display, generation: generation) else { return nil }
        guard settings.enabled, !(request.snap?.isCorner == true && settings.selection == .mostRecent) else {
            return (single, nil)
        }
        guard let snapshot else { return (single, "Companions could not be verified; only the dragged window will snap.") }
        switch plan(snapshot: snapshot, anchorID: anchor.id.window, request: request,
            selection: settings.selection, maximumWindows: settings.maximumWindows,
            preferredCompanion: preferredCompanion, preparingFor: destination) {
        case .ready(let group): return (group, nil)
        case .noPeer: return (single, nil)
        case .rejected: return (single, "Companions cannot be arranged; only the dragged window will snap.")
        }
    }

    static func singleSnap(anchor: WindowLayoutWindow, request: SidebarPlacementRequest,
                           destination: WindowLayoutScope, display: WindowLayoutDisplay,
                           generation: Int) -> WindowLayoutPlan? {
        guard anchor.eligible, let snap = request.snap, snap != .maximize,
              destination.displayID == display.id,
              SidebarPlacementGeometry.matches(request.workArea, display.workArea),
              SidebarPlacementGeometry.isValid(request.frame), SidebarPlacementGeometry.isValid(display.workArea),
              anchor.minimum.width.isFinite, anchor.minimum.height.isFinite,
              anchor.minimum.width >= 0, anchor.minimum.height >= 0 else { return nil }
        let size = CGSize(width: max(request.frame.width, anchor.minimum.width),
                          height: max(request.frame.height, anchor.minimum.height))
        let target = SidebarPlacementGeometry.constrained(
            SidebarPlacementGeometry.snapFrame(snap, size: size, inAX: display.workArea), to: display.workArea)
        return WindowLayoutPlan(scope: destination, desktopGeneration: generation, workArea: display.workArea,
            snap: snap, scale: display.scale, anchor: anchor, peers: [],
            constraints: [anchor.id: .reported(for: anchor, workArea: display.workArea)], frames: [anchor.id: target])
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        return !intersection.isNull && intersection.width > 2 && intersection.height > 2
    }
}
