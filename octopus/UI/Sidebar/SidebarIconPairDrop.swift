import AppKit

enum PairDropDirection: String, CaseIterable {
    case left, right, top, bottom

    var snap: SidebarSnapTarget {
        switch self {
        case .left: return .left
        case .right: return .right
        case .top: return .top
        case .bottom: return .bottom
        }
    }
    var opposite: Self {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    // Keep the chosen side through the centre and near diagonals so small pointer movements do not flip the preview.
    static func choose(at point: CGPoint, in frame: CGRect, previous: Self?) -> Self? {
        guard SidebarPlacementGeometry.isValid(frame), frame.contains(point) else { return nil }
        let dx = (point.x - frame.midX) / (frame.width / 2)
        let dy = (point.y - frame.midY) / (frame.height / 2)
        if max(abs(dx), abs(dy)) < 0.25 { return previous }
        if abs(abs(dx) - abs(dy)) < 0.1, let previous { return previous }
        if abs(dx) >= abs(dy) { return dx < 0 ? .left : .right }
        return dy > 0 ? .top : .bottom // AppKit screen coordinates grow upward.
    }
}

struct SidebarIconPairTarget {
    let ownerID: UUID
    let entryID: SidebarEntryID
    let window: SidebarWindowID
    let title: String
    let frame: CGRect
    let isVisible: Bool
    // A formerly visible icon stays reserved even if its window closes during this drag.
    var reservesPairDrop = false
}

enum SidebarDropIntent {
    case pair(SidebarIconPairTarget, PairDropDirection?)
    case tabs(SidebarIconPairTarget)
    case blocked
    case other
}

// A rejected visible icon consumes the drop; it must not accidentally become a Desktop transfer.
enum SidebarIconPairDrop {
    static func resolve(at point: CGPoint, source: SidebarWindowID, sourceVisible: Bool,
                        targets: [SidebarIconPairTarget], previousTarget: SidebarWindowID?,
                        previousDirection: PairDropDirection?, tabGrouping: Bool = false) -> SidebarDropIntent {
        guard sourceVisible, let target = targets.first(where: { $0.frame.contains(point) }) else { return .other }
        if !target.isVisible { return target.reservesPairDrop || target.window == previousTarget ? .blocked : .other }
        guard target.window != source else { return .blocked }
        if tabGrouping, WindowTabGeometry.centre(of: target.frame).contains(point) { return .tabs(target) }
        let previous = previousTarget == target.window ? previousDirection : nil
        return .pair(target, PairDropDirection.choose(at: point, in: target.frame, previous: previous))
    }
}
