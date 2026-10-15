import AppKit

struct WindowTabAlignmentResult {
    var windows: [WindowLayoutWindow] = []
    var reason: String?
    var placementFailed = false
}

// One native boundary for group alignment. No app hiding, minimising, offscreen
// parking, automatic retries, or speculative rollback of another app's changes.
enum WindowTabGroupService {
    static func move(_ expected: [WindowLayoutWindow], selected: WindowLayoutIdentity,
                     from original: CGRect, to frame: CGRect, scope: WindowLayoutScope,
                     displays: [WindowLayoutDisplay], access: WindowControlAccess,
                     budget: WindowControlBudget) -> WindowTabAlignmentResult {
        guard let display = displays.first(where: { $0.id == scope.displayID }), display.workArea.contains(frame) else {
            return WindowTabAlignmentResult(reason: "Move the group within its current display.")
        }
        return move(expected, selected: selected, from: original, to: frame, scope: scope,
            canContinue: { budget.isCurrent },
            read: { access.read($0.id.window, displays: displays, budget: budget, expected: $0, forFocus: true).window },
            write: { window, requested in
                access.write(window, frame: requested, workArea: display.workArea, destination: scope,
                    displays: displays, budget: budget, policy: .preparedSnap, resize: false, allowCovered: true)
            })
    }

    static func move(_ expected: [WindowLayoutWindow], selected: WindowLayoutIdentity,
                     from original: CGRect, to frame: CGRect, scope: WindowLayoutScope,
                     canContinue: () -> Bool, read: (WindowLayoutWindow) -> WindowLayoutWindow?,
                     write: (WindowLayoutWindow, CGRect) -> SidebarPlacementResult) -> WindowTabAlignmentResult {
        guard SidebarPlacementGeometry.matches(CGRect(origin: .zero, size: original.size), CGRect(origin: .zero, size: frame.size)),
              let active = expected.first(where: { $0.id == selected }),
              SidebarPlacementGeometry.matches(active.frame, original),
              expected.allSatisfy({ SidebarPlacementGeometry.matches(CGRect(origin: .zero, size: $0.frame.size),
                  CGRect(origin: .zero, size: frame.size)) }) else {
            return WindowTabAlignmentResult(reason: "The group's windows changed during the drag. Drag again.")
        }
        // Move the selected member first, so a partial move never leaves the
        // authoritative group frame behind its already-moved inactive tabs.
        let ordered = [active] + expected.filter { $0.id != selected }
        var result = align(ordered, to: frame, scope: scope, canContinue: canContinue, read: read, write: write)
        let byID = Dictionary(uniqueKeysWithValues: result.windows.map { ($0.id, $0) })
        result.windows = expected.compactMap { byID[$0.id] }
        return result
    }

    // AXRaise reports that the action was triggered. Confirm the actual focus and
    // stacking result, without sending another activation or raise command.
    static func confirmFocus(canContinue: () -> Bool, readConfirmed: () -> Bool,
                             wait: () -> Void, maximumReads: Int = 8) -> Bool {
        for index in 0..<maximumReads {
            guard canContinue() else { return false }
            if readConfirmed() { return canContinue() }
            if index + 1 < maximumReads, canContinue() { wait() }
        }
        return false
    }

    // Switching is a focus operation, not another group layout. Hidden apps may be
    // explicitly shown by the focus path; minimised or moved-away members stay separate.
    static func selection(_ expected: WindowLayoutWindow, scope: WindowLayoutScope,
                          canContinue: () -> Bool, read: (WindowLayoutWindow) -> WindowLayoutWindow?) -> WindowLayoutWindow? {
        guard canContinue(), let current = read(expected), canContinue(),
              current.id == expected.id, current.scope == scope, !current.minimized else { return nil }
        return current
    }

    static func align(_ expected: [WindowLayoutWindow], to frame: CGRect, scope: WindowLayoutScope,
                      displays: [WindowLayoutDisplay], access: WindowControlAccess,
                      budget: WindowControlBudget) -> WindowTabAlignmentResult {
        guard budget.isCurrent, let display = displays.first(where: { $0.id == scope.displayID }) else {
            return WindowTabAlignmentResult(reason: "The group's display changed.")
        }
        return align(expected, to: frame, scope: scope, canContinue: { budget.isCurrent },
            read: { access.read($0.id.window, displays: displays, budget: budget, expected: $0, forFocus: true).window },
            write: { window, requested in
                access.write(window, frame: requested, workArea: display.workArea, destination: scope,
                    displays: displays, budget: budget, policy: .preparedSnap, allowCovered: true)
            })
    }

    static func align(_ expected: [WindowLayoutWindow], to frame: CGRect, scope: WindowLayoutScope,
                      canContinue: () -> Bool, read: (WindowLayoutWindow) -> WindowLayoutWindow?,
                      write: (WindowLayoutWindow, CGRect) -> SidebarPlacementResult) -> WindowTabAlignmentResult {
        var live: [WindowLayoutWindow] = []
        for window in expected {
            guard canContinue(), let current = read(window),
                  current.id == window.id, current.scope == scope,
                  SidebarPlacementGeometry.matches(current.frame, window.frame) else {
                return WindowTabAlignmentResult(reason: "A window changed before the tabs could be arranged.")
            }
            live.append(current)
        }
        guard WindowTabGeometry.fits(frame, windows: live, scope: scope) else {
            // A known size conflict is permanent for this arrangement; a sheet or
            // temporary unavailable window is not proof that the group must separate.
            let sizeConflict = !live.isEmpty && live.allSatisfy { $0.eligible && $0.scope == scope }
            return WindowTabAlignmentResult(reason: "These windows cannot share this size or Desktop.", placementFailed: sizeConflict)
        }
        var result = WindowTabAlignmentResult()
        for window in live {
            guard canContinue(), let current = read(window), current.id == window.id, current.eligible,
                  current.scope == scope, SidebarPlacementGeometry.matches(current.frame, window.frame) else {
                result.reason = "A window changed before the next tab could be arranged."
                return result
            }
            if !SidebarPlacementGeometry.matches(window.frame, frame) {
                switch write(window, frame) {
                case .placed(_, adjusted: false): break
                case .cancelled:
                    result.reason = "The tab arrangement was interrupted. Some windows may have moved."
                    return result
                case .failed(_), .placed(_, _):
                    result.placementFailed = true
                    result.reason = "An app could not match the tab group's size. Some windows may have moved."
                    return result
                }
            }
            guard canContinue(), let actual = read(window),
                  actual.id == window.id, actual.eligible, actual.scope == scope,
                  SidebarPlacementGeometry.matches(actual.frame, frame) else {
                result.reason = "The tab arrangement could not be confirmed. Some windows may have moved."
                return result
            }
            result.windows.append(actual)
        }
        // Recheck earlier members too: a sheet or external move may occur during a later write.
        for window in result.windows {
            guard canContinue(), let current = read(window),
                  current.id == window.id, current.eligible, current.scope == scope,
                  SidebarPlacementGeometry.matches(current.frame, frame) else {
                result.reason = "A window changed while the tab group was being arranged."
                return result
            }
        }
        return result
    }
}
