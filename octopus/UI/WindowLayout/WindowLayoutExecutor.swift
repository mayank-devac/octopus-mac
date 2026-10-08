import AppKit

enum WindowLayoutBatchResult {
    case applied([WindowLayoutIdentity: CGRect])
    case stopped(String)
}

enum WindowLayoutExecutor {
    static func apply(_ plan: WindowLayoutPlan, canContinue: () -> Bool,
                      read: (WindowLayoutIdentity) -> WindowLayoutWindow?,
                      write: (WindowLayoutIdentity, CGRect, TimeInterval) -> SidebarPlacementResult,
                      clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                      restoring: Bool = false) -> WindowLayoutBatchResult {
        let deadline = clock() + 4
        func live(_ original: WindowLayoutWindow) -> WindowLayoutWindow? {
            guard canContinue(), clock() < deadline, let window = read(original.id),
                  window.id == original.id, window.scope == plan.scope, window.eligible else { return nil }
            return window
        }
        func anchorUnchanged() -> Bool {
            guard let anchor = live(plan.anchor) else { return false }
            return SidebarPlacementGeometry.matches(anchor.frame, plan.anchor.frame)
        }
        guard anchorUnchanged() else { return .stopped("Your snapped window changed before adjustment could start.") }
        for peer in plan.peers {
            guard let current = live(peer), SidebarPlacementGeometry.matches(current.frame, peer.frame) else {
                return .stopped("The other windows changed before adjustment could start.")
            }
        }
        var touched: [WindowLayoutWindow] = []
        var observed: [WindowLayoutIdentity: CGRect] = [:]
        var failure: String?
        for peer in plan.peers {
            guard let target = plan.frames[peer.id], anchorUnchanged(), let current = live(peer),
                  SidebarPlacementGeometry.matches(current.frame, peer.frame) else {
                failure = "A window or Desktop changed during adjustment."; break
            }
            if SidebarPlacementGeometry.matches(current.frame, target) { observed[peer.id] = current.frame; continue }
            touched.append(peer)
            let result = write(peer.id, target, deadline)
            if let actual = read(peer.id), actual.id == peer.id, actual.scope == plan.scope { observed[peer.id] = actual.frame }
            guard case .placed(_, adjusted: false) = result,
                  let actual = observed[peer.id], SidebarPlacementGeometry.matches(actual, target) else {
                failure = result.message ?? "An app could not finish resizing."; break
            }
        }
        if failure == nil {
            guard anchorUnchanged() else { return .stopped("Your snapped window changed. Other windows may have moved.") }
            for peer in plan.peers {
                guard let target = plan.frames[peer.id], let actual = live(peer),
                      SidebarPlacementGeometry.matches(actual.frame, target) else {
                    failure = "An app changed its frame before adjustment finished."; break
                }
                observed[peer.id] = actual.frame
            }
            if !restoring {
                let values = Array(observed.values)
                for index in values.indices {
                    if WindowLayoutPlanner.overlaps(values[index], plan.anchor.frame)
                        || values.dropFirst(index + 1).contains(where: { WindowLayoutPlanner.overlaps(values[index], $0) }) {
                        failure = "The apps could not achieve a non-overlapping layout."; break
                    }
                }
            }
        }
        if failure == nil { return .applied(observed) }
        let recoveryDeadline = clock() + 2
        for peer in touched.reversed() {
            guard canContinue(), clock() < recoveryDeadline, let expected = observed[peer.id],
                  !SidebarPlacementGeometry.matches(expected, peer.frame),
                  let current = read(peer.id), current.id == peer.id, current.scope == plan.scope, current.eligible,
                  SidebarPlacementGeometry.matches(current.frame, expected) else { continue }
            _ = write(peer.id, peer.frame, recoveryDeadline)
        }
        return .stopped("\(failure!) Your snapped window stays in place; other windows may have moved.")
    }
}
