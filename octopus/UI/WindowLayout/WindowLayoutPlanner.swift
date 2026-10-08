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
                         read: (WindowLayoutCandidate) -> WindowLayoutCandidateResolution) -> WindowLayoutSnapshot {
        let ordered = candidates.sorted { a, b in
            if a.recency != b.recency { return a.recency > b.recency }
            if a.stackOrder != b.stackOrder { return a.stackOrder < b.stackOrder }
            return a.window.windowID < b.window.windowID
        }
        var windows = [anchor]
        var complete = true
        for candidate in ordered where candidate.window != anchor.id.window {
            let resolution = read(candidate)
            if case .excluded = resolution { continue }
            guard case .window(let window) = resolution, window.scope == anchor.scope else {
                complete = false; break
            }
            guard window.visible, !window.blocked else { continue }
            windows.append(window)
            if selection == .mostRecent { break }
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
        case .maximize: return nil
        }
    }

    static func plan(snapshot: WindowLayoutSnapshot, anchorID: SidebarWindowID,
                     request: SidebarPlacementRequest, selection: WindowLayoutSelection = .mostRecent,
                     learned: [WindowLayoutIdentity: WindowLayoutSizeConstraint] = [:]) -> WindowLayoutPlanningResult {
        if !snapshot.complete { return .rejected(snapshot.failureReason ?? "An open window could not be verified. Your snap stays in place.") }
        guard snapshot.complete, Set(snapshot.windows.map { $0.id.window }).count == snapshot.windows.count,
              let snap = request.snap,
              let anchor = snapshot.windows.first(where: { $0.id.window == anchorID }), anchor.eligible,
              let display = snapshot.displays.first(where: { $0.id == anchor.scope.displayID }),
              SidebarPlacementGeometry.matches(display.workArea, request.workArea),
              SidebarPlacementGeometry.matches(anchor.frame, request.frame) else {
            return .rejected("The snapped window's display or Desktop could not be verified.")
        }
        let peers = snapshot.windows(in: anchor.scope).filter { $0.id != anchor.id && $0.visible && !$0.blocked }
        // Unobserved startup history falls back to the frontmost CG surface, never app enumeration order.
        let ordered = peers.sorted { a, b in
            if a.recency != b.recency { return a.recency > b.recency }
            if a.stackOrder != b.stackOrder { return a.stackOrder < b.stackOrder }
            return a.id.window.windowID < b.id.window.windowID
        }
        let selected = selection == .mostRecent ? Array(ordered.prefix(1)) : ordered
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
        let constraints = Dictionary(uniqueKeysWithValues: windows.map { window in
            (window.id, WindowLayoutSizeConstraint.initial(for: window, workArea: request.workArea,
                                                            learned: learned[window.id]))
        })
        guard let allocation = WindowLayoutAllocator.allocate(workArea: request.workArea, snap: snap,
            scale: display.scale, anchor: anchor.id, peers: selected.map(\.id), constraints: constraints) else {
            return .rejected("These windows cannot fit together on this display without overlapping.")
        }
        return .ready(WindowLayoutPlan(scope: anchor.scope, desktopGeneration: snapshot.desktopGeneration,
            workArea: request.workArea, snap: snap, scale: display.scale,
            anchor: anchor, peers: selected, constraints: constraints, frames: allocation.frames))
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        return !intersection.isNull && intersection.width > 2 && intersection.height > 2
    }
}
