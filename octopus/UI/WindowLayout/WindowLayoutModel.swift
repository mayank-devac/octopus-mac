import AppKit

struct WindowLayoutIdentity: Hashable {
    let window: SidebarWindowID
    // Minted by the reader for each admitted surface; never persisted.
    let generation: UInt64
}

struct WindowLayoutScope: Hashable {
    let displayID: String
    let spaceID: UInt64
}

struct WindowLayoutDisplay {
    let id: String
    let frame: CGRect
    let workArea: CGRect // AX points, using the same primary top as the drag path.
    let scale: CGFloat
    let name: String

    @MainActor static func connected() -> [Self] {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let id = SidebarSettings.monitorID(screen) else { return nil }
            return Self(id: id, frame: SidebarPlacementGeometry.flip(screen.frame, primaryTop: primaryTop),
                        workArea: SidebarPlacementGeometry.flip(screen.visibleFrame, primaryTop: primaryTop),
                        scale: max(1, screen.backingScaleFactor), name: screen.localizedName)
        }
    }
}

struct WindowLayoutWindow {
    let id: WindowLayoutIdentity
    let scope: WindowLayoutScope
    let frame: CGRect
    let minimum: CGSize
    // False means the app did not expose AXMinSize/AXMinimumSize; zero is then only a safe planning fallback.
    let minimumReported: Bool
    let canMove: Bool
    let canResize: Bool
    let hidden: Bool
    let minimized: Bool
    let blocked: Bool
    let recency: UInt64
    let stackOrder: Int

    var visible: Bool { !hidden && !minimized }
    var eligible: Bool { visible && !blocked && canMove && canResize }
}

struct WindowLayoutSnapshot {
    let windows: [WindowLayoutWindow]
    let displays: [WindowLayoutDisplay]
    let complete: Bool
    let desktopGeneration: Int
    var failureReason: String? = nil

    func windows(in scope: WindowLayoutScope) -> [WindowLayoutWindow] {
        windows.filter { $0.scope == scope }
    }
}

struct WindowLayoutCandidate {
    let window: SidebarWindowID
    let recency: UInt64
    let stackOrder: Int
}

enum WindowLayoutCandidateResolution {
    case window(WindowLayoutWindow)
    case excluded
    case unavailable
}

struct WindowLayoutPlan {
    let scope: WindowLayoutScope
    let desktopGeneration: Int
    let workArea: CGRect
    let snap: SidebarSnapTarget
    let scale: CGFloat
    let anchor: WindowLayoutWindow
    let peers: [WindowLayoutWindow]
    let constraints: [WindowLayoutIdentity: WindowLayoutSizeConstraint]
    // Includes the anchor because hidden app limits may require moving the shared split boundary.
    let frames: [WindowLayoutIdentity: CGRect]

    var windows: [WindowLayoutWindow] { [anchor] + peers }
}

enum WindowLayoutPlanningResult {
    case ready(WindowLayoutPlan)
    case rejected(String)
    case noPeer
}

struct WindowLayoutCompletedSnap {
    let window: SidebarWindowID
    let request: SidebarPlacementRequest
    let startedAt: TimeInterval

    func isCurrent(after latestAction: TimeInterval) -> Bool { startedAt >= latestAction }
}

// Preserve the two icons' exact window identities; commit must not choose a different app window.
struct WindowPairSnapRequest {
    let source: SidebarWindowID
    let target: SidebarWindowID
    let direction: PairDropDirection
    let startedAt: TimeInterval
    func isCurrent(after latestAction: TimeInterval) -> Bool { startedAt >= latestAction }
}

struct WindowPairSnapPlan {
    let source: WindowLayoutWindow
    let target: WindowLayoutWindow
    let destination: WindowLayoutScope
    let workArea: CGRect
    let sourceFrame: CGRect
    let targetFrame: CGRect
}

// Undo compares the achieved state before restoring both original visible display/Desktop scopes.
struct WindowPairUndoRecord {
    let plan: WindowPairSnapPlan
    let sourceAfter: WindowLayoutWindow
    let targetAfter: WindowLayoutWindow
}

// Cancellation is visible to the serial AX queue while a call is blocked.
final class WindowLayoutBatchToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let frontmostPID: pid_t?
    init(frontmostPID: pid_t?) { self.frontmostPID = frontmostPID }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
