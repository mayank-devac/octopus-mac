import AppKit

struct WindowPairPreparation {
    let source: WindowLayoutWindow
    let target: WindowLayoutWindow
    let display: WindowLayoutDisplay
}

enum WindowPairResult {
    case applied(WindowLayoutWindow, WindowLayoutWindow)
    case stopped(String)
}

// Explicit pairing never selects a third window and never guesses ownership for automatic rollback.
enum WindowPairSnapService {
    static func prepare(source: SidebarWindowID, target: SidebarWindowID,
                        displays: [WindowLayoutDisplay], access: WindowControlAccess,
                        budget: WindowControlBudget) -> WindowPairPreparation? {
        guard source != target, budget.isCurrent,
              let a = access.read(source, displays: displays, budget: budget).window,
              let b = access.read(target, displays: displays, budget: budget).window,
              a.eligible, b.eligible, let display = displays.first(where: { $0.id == b.scope.displayID }),
              budget.isCurrent else { return nil }
        return WindowPairPreparation(source: a, target: b, display: display)
    }

    static func execute(_ plan: WindowPairSnapPlan, canContinue: () -> Bool,
                        read: (WindowLayoutWindow) -> WindowLayoutWindow?,
                        write: (WindowLayoutWindow, CGRect, WindowLayoutScope) -> SidebarPlacementResult) -> WindowPairResult {
        func matches(_ expected: WindowLayoutWindow) -> WindowLayoutWindow? {
            guard canContinue(), let current = read(expected), current.id == expected.id, current.eligible,
                  current.scope == expected.scope, SidebarPlacementGeometry.matches(current.frame, expected.frame) else { return nil }
            return current
        }
        guard let source = matches(plan.source), let target = matches(plan.target) else {
            return .stopped("The selected windows changed before pairing could start.")
        }
        // Make room on the destination first; do not cover B before A has finished crossing displays.
        if !SidebarPlacementGeometry.matches(target.frame, plan.targetFrame) {
            guard case .placed(_, adjusted: false) = write(target, plan.targetFrame, plan.destination) else {
                return .stopped("The target app could not finish resizing; a window may have moved.")
            }
        }
        guard canContinue(), let currentTarget = read(target), currentTarget.id == target.id,
              currentTarget.eligible, currentTarget.scope == plan.destination,
              SidebarPlacementGeometry.matches(currentTarget.frame, plan.targetFrame), matches(source) != nil else {
            return .stopped("Pairing stopped to preserve a window change; a window may have moved.")
        }
        if source.scope != plan.destination || !SidebarPlacementGeometry.matches(source.frame, plan.sourceFrame) {
            guard case .placed(_, adjusted: false) = write(source, plan.sourceFrame, plan.destination) else {
                return .stopped("The dragged app could not finish placement; the target window may have moved.")
            }
        }
        guard canContinue(), let a = read(source), let b = read(target), a.id == source.id, b.id == target.id,
              a.eligible, b.eligible, a.scope == plan.destination, b.scope == plan.destination,
              SidebarPlacementGeometry.matches(a.frame, plan.sourceFrame),
              SidebarPlacementGeometry.matches(b.frame, plan.targetFrame), !WindowLayoutPlanner.overlaps(a.frame, b.frame) else {
            return .stopped("The apps could not confirm the requested pair; some windows may have moved.")
        }
        return .applied(a, b)
    }

    // Undo is an explicit user action, and only intact post-pair identities/frames authorise restoration.
    static func undo(_ record: WindowPairUndoRecord, canContinue: () -> Bool,
                     scopeVisible: (WindowLayoutScope) -> Bool,
                     read: (WindowLayoutWindow) -> WindowLayoutWindow?,
                     write: (WindowLayoutWindow, CGRect, WindowLayoutScope) -> SidebarPlacementResult) -> WindowPairResult {
        guard canContinue(), scopeVisible(record.plan.source.scope), scopeVisible(record.plan.target.scope),
              let a = read(record.sourceAfter), let b = read(record.targetAfter),
              a.id == record.sourceAfter.id, b.id == record.targetAfter.id, a.eligible, b.eligible,
              a.scope == record.sourceAfter.scope, b.scope == record.targetAfter.scope,
              SidebarPlacementGeometry.matches(a.frame, record.sourceAfter.frame),
              SidebarPlacementGeometry.matches(b.frame, record.targetAfter.frame) else {
            return .stopped("Undo is unavailable because the windows or their original Desktops changed.")
        }
        for (current, original) in [(a, record.plan.source), (b, record.plan.target)] {
            guard canContinue(), scopeVisible(original.scope),
                  let live = read(current), live.id == current.id, live.eligible, live.scope == current.scope,
                  SidebarPlacementGeometry.matches(live.frame, current.frame),
                  case .placed(_, adjusted: false) = write(live, original.frame, original.scope) else {
                return .stopped("Undo stopped; some windows may have returned to their previous positions.")
            }
        }
        guard canContinue(), let restoredA = read(a), let restoredB = read(b),
              restoredA.id == a.id, restoredB.id == b.id, restoredA.eligible, restoredB.eligible,
              restoredA.scope == record.plan.source.scope, restoredB.scope == record.plan.target.scope,
              SidebarPlacementGeometry.matches(restoredA.frame, record.plan.source.frame),
              SidebarPlacementGeometry.matches(restoredB.frame, record.plan.target.frame) else {
            return .stopped("The apps could not confirm Undo.")
        }
        return .applied(restoredA, restoredB)
    }
}
