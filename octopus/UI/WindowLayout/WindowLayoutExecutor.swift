import AppKit

enum WindowLayoutBatchResult {
    case applied([WindowLayoutIdentity: CGRect])
    case stopped(String)
}

enum WindowLayoutExecutor {
    // Learn an app's hidden size limit only from its verified post-write frame, then redistribute.
    static func apply(_ plan: WindowLayoutPlan, canContinue: () -> Bool,
                      read: (WindowLayoutIdentity) -> WindowLayoutWindow?,
                      write: (WindowLayoutWindow, CGRect, TimeInterval) -> SidebarPlacementResult,
                      clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                      deadline requestedDeadline: TimeInterval? = nil,
                      onLearn: (WindowLayoutIdentity, WindowLayoutSizeConstraint) -> Void = { _, _ in }) -> WindowLayoutBatchResult {
        let deadline = requestedDeadline ?? clock() + 4
        let windows = plan.windows
        let identities = windows.map(\.id)
        guard identities.count == Set(identities).count,
              plan.frames.count == windows.count else { return .stopped("The window list changed before adjustment.") }
        var constraints = plan.constraints
        var frames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
        var targets = plan.frames

        func current(_ window: WindowLayoutWindow) -> WindowLayoutWindow? {
            guard canContinue(), clock() < deadline,
                  let actual = read(window.id), actual.id == window.id,
                  actual.scope == plan.scope, actual.eligible,
                  let expected = frames[window.id],
                  SidebarPlacementGeometry.matches(actual.frame, expected) else { return nil }
            return actual
        }
        // Check every participant before the first write. An external move ends this operation.
        guard windows.allSatisfy({ current($0) != nil }) else {
            return .stopped("A window or Desktop changed before adjustment could start.")
        }

        for _ in 0..<(windows.count * 2 + 1) {
            guard canContinue(), clock() < deadline else {
                return .stopped("Layout timed out; windows already adjusted keep their current positions.")
            }
            guard let oldAnchor = frames[plan.anchor.id], let newAnchor = targets[plan.anchor.id] else {
                return .stopped("The snapped window could not be verified.")
            }
            // Make room before enlarging a companion. When the anchor grows, move companions first.
            let anchorShrinks = newAnchor.width < oldAnchor.width - 2 || newAnchor.height < oldAnchor.height - 2
            let order = anchorShrinks ? [plan.anchor] + plan.peers : plan.peers + [plan.anchor]
            var learned = false
            for window in order {
                guard let target = targets[window.id], let live = current(window) else {
                    return .stopped("A window changed during adjustment; achieved positions were kept.")
                }
                if SidebarPlacementGeometry.matches(live.frame, target) { continue }
                // Carry this exact starting frame to native preflight; do not replace it with another read.
                let result = write(live, target, deadline)
                guard canContinue(), clock() < deadline else {
                    return .stopped("Layout stopped; achieved positions were kept.")
                }
                guard let actual = read(window.id), actual.id == window.id,
                      actual.scope == plan.scope, actual.eligible else {
                    return .stopped("The app's final window state could not be verified.")
                }
                frames[window.id] = actual.frame
                let writerFrame: CGRect
                let wasAdjusted: Bool
                switch result {
                case .cancelled:
                    return .stopped("Layout was cancelled; achieved positions were kept.")
                case .failed(let reason):
                    return .stopped("\(reason) Achieved positions were kept.")
                case .placed(let frame, let adjusted):
                    writerFrame = frame
                    wasAdjusted = adjusted
                }
                if SidebarPlacementGeometry.matches(actual.frame, target) { continue }
                // A newer external move must not become a supposed app size limit.
                guard wasAdjusted, SidebarPlacementGeometry.matches(writerFrame, actual.frame),
                      let previous = constraints[window.id],
                      let revised = previous.observing(requested: target, achieved: actual.frame),
                      revised != previous else {
                    return .stopped("An app did not accept its assigned position; achieved positions were kept.")
                }
                constraints[window.id] = revised
                onLearn(window.id, revised)
                learned = true
                break
            }
            if learned {
                guard let allocation = WindowLayoutAllocator.allocate(workArea: plan.workArea,
                    snap: plan.snap, scale: plan.scale, anchor: plan.anchor.id,
                    peers: plan.peers.map(\.id), constraints: constraints) else {
                    return .stopped("The apps' size limits cannot fit on this display; achieved positions were kept.")
                }
                targets = allocation
                continue
            }
            let final = windows.compactMap { current($0) }
            guard canContinue(), clock() < deadline, final.count == windows.count,
                  final.allSatisfy({ window in
                      targets[window.id].map { SidebarPlacementGeometry.matches(window.frame, $0) } == true
                  }) else {
                return .stopped("A window changed before the layout finished; achieved positions were kept.")
            }
            for (index, window) in final.enumerated() {
                guard !final.dropFirst(index + 1).contains(where: { WindowLayoutPlanner.overlaps(window.frame, $0.frame) }) else {
                    return .stopped("The apps could not confirm a non-overlapping layout.")
                }
            }
            guard canContinue(), clock() < deadline else { return .stopped("Layout was interrupted before confirmation.") }
            return .applied(Dictionary(uniqueKeysWithValues: final.map { ($0.id, $0.frame) }))
        }
        return .stopped("The apps changed their size limits during layout; achieved positions were kept.")
    }

    // Undo is user-requested. Confirm the entire achieved layout before restoring any original frame.
    static func restore(_ plan: WindowLayoutPlan, achieved: [WindowLayoutIdentity: CGRect],
                        canContinue: () -> Bool,
                        read: (WindowLayoutIdentity) -> WindowLayoutWindow?,
                        write: (WindowLayoutWindow, CGRect, TimeInterval) -> SidebarPlacementResult,
                        clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        deadline requestedDeadline: TimeInterval? = nil) -> WindowLayoutBatchResult {
        let deadline = requestedDeadline ?? clock() + 4
        let order = plan.peers + [plan.anchor]
        guard achieved.count == order.count, order.allSatisfy({ original in
            guard canContinue(), clock() < deadline,
                  let live = read(original.id), let frame = achieved[original.id] else { return false }
            return live.id == original.id && live.scope == plan.scope && live.eligible
                && SidebarPlacementGeometry.matches(live.frame, frame)
        }) else { return .stopped("Undo is unavailable because a window or Desktop changed.") }

        for original in order {
            guard canContinue(), clock() < deadline, let live = read(original.id),
                  live.id == original.id, live.scope == plan.scope, live.eligible,
                  let expected = achieved[original.id],
                  SidebarPlacementGeometry.matches(live.frame, expected) else {
                return .stopped("Undo stopped because a window changed; achieved positions were kept.")
            }
            if SidebarPlacementGeometry.matches(live.frame, original.frame) { continue }
            let result = write(live, original.frame, deadline)
            guard case .placed = result, canContinue(), clock() < deadline,
                  let actual = read(original.id), actual.id == original.id,
                  actual.scope == plan.scope, actual.eligible,
                  SidebarPlacementGeometry.matches(actual.frame, original.frame) else {
                return .stopped("An app could not finish Undo; some windows may have moved.")
            }
        }
        guard canContinue(), clock() < deadline, order.allSatisfy({ original in
            guard let live = read(original.id) else { return false }
            return live.id == original.id && live.scope == plan.scope && live.eligible
                && SidebarPlacementGeometry.matches(live.frame, original.frame)
        }), canContinue(), clock() < deadline else { return .stopped("The apps could not confirm Undo.") }
        return .applied(Dictionary(uniqueKeysWithValues: order.map { ($0.id, $0.frame) }))
    }
}
