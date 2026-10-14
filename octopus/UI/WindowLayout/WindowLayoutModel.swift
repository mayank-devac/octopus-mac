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
    // False means AXMinSize/AXMinimumSize was unavailable. Zero is an unknown lower-bound placeholder;
    // the achieved frame must still be verified, and may reveal a larger limit.
    let minimumReported: Bool
    let canMove: Bool
    let canResize: Bool
    let hidden: Bool
    let minimized: Bool
    let blocked: Bool
    let recency: UInt64
    let stackOrder: Int

    var visible: Bool { !hidden && !minimized }
    var movable: Bool { visible && !blocked && canMove }
    var eligible: Bool { movable && canResize }
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
    var frames: [WindowLayoutIdentity: CGRect]
    // The selected edge layout's columns/rows stay fixed while its shared divider moves.
    var edgeGroups: [[WindowLayoutIdentity]]? = nil

    var windows: [WindowLayoutWindow] { [anchor] + peers }
}

struct WindowSnapSettings: Equatable {
    let enabled: Bool
    let selection: WindowLayoutSelection
    let maximumWindows: Int
    var mode: WindowSnapMode = .legacy

    static func current() -> Self {
        Self(enabled: WindowLayoutSettings.enabled(), selection: WindowLayoutSettings.selection(),
             maximumWindows: WindowLayoutSettings.maximumWindows(), mode: WindowLayoutSettings.mode())
    }
}

// Original frames/scopes are retained independently of the displayed destination frames.
struct WindowLayoutPreparedSnap {
    var plan: WindowLayoutPlan
    let request: SidebarPlacementRequest
    let displays: [WindowLayoutDisplay]
    let settings: WindowSnapSettings
    let generation: Int
    let frontmostPID: pid_t?
    let frontmostWindow: SidebarWindowID?
    let fallbackReason: String?

    var allowsDividerAdjustment: Bool {
        settings.mode == .current && plan.anchor.scope == plan.scope && !plan.peers.isEmpty
            && !plan.snap.isCorner && plan.snap != .maximize && plan.edgeGroups != nil
    }

    func isCurrent(generation: Int, settings: WindowSnapSettings,
                   displays: [WindowLayoutDisplay], frontmostPID: pid_t?) -> Bool {
        self.generation == generation && self.settings == settings
            && self.frontmostPID == frontmostPID && displaysMatch(displays)
    }

    func displaysMatch(_ current: [WindowLayoutDisplay]) -> Bool {
        displays.count == current.count && displays.allSatisfy { old in
            current.contains { $0.id == old.id && $0.frame == old.frame && $0.workArea == old.workArea && $0.scale == old.scale }
        }
    }
}

// Pointer coordinates are AX points. This value contains geometry only; it never reads or writes apps.
struct WindowLayoutDividerGesture {
    let original: WindowLayoutPreparedSnap
    let startPoint: CGPoint
    let startLength: CGFloat
    private(set) var preview: WindowLayoutPreparedSnap
    private(set) var isLimited = false

    init?(prepared: WindowLayoutPreparedSnap, at point: CGPoint) {
        guard prepared.allowsDividerAdjustment, point.x.isFinite, point.y.isFinite,
              let frame = prepared.plan.frames[prepared.plan.anchor.id], SidebarPlacementGeometry.isValid(frame) else { return nil }
        original = prepared
        startPoint = point
        startLength = prepared.plan.snap == .left || prepared.plan.snap == .right ? frame.width : frame.height
        preview = prepared
    }

    @discardableResult mutating func update(at point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        let horizontal = original.plan.snap == .left || original.plan.snap == .right
        let delta = horizontal ? point.x - startPoint.x : point.y - startPoint.y
        let growsForward = original.plan.snap == .left || original.plan.snap == .top
        let requested = startLength + (growsForward ? delta : -delta)
        guard let adjusted = WindowLayoutPlanner.adjustingDivider(original, anchorLength: requested),
              let actual = adjusted.plan.frames[adjusted.plan.anchor.id] else { return false }
        preview = adjusted
        isLimited = abs((horizontal ? actual.width : actual.height) - requested) > 1 / original.plan.scale
        return true
    }
}

struct WindowLayoutSnapResult {
    // Only setter results confirmed by live readback enter this list. It can describe a partial commit.
    var achieved: [WindowLayoutIdentity: WindowLayoutWindow] = [:]
    var reason: String?
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
    var achievedFrame: CGRect? = nil
    // Captured before placement changes focus; never substitute the newly snapped window.
    var preferredCompanion: SidebarWindowID? = nil

    var verifiedFrame: CGRect { achievedFrame ?? request.frame }

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
