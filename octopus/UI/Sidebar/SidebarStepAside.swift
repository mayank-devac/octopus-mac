import CoreGraphics
import Foundation

////////////////////
//// Step aside (Delay opening)
/// The sidebar works normally while the pointer is on it. If the pointer rests there unused for the
// delay (no movement, click, scroll or open menu), the sidebar fades and lets clicks reach the window
// underneath, until the pointer leaves it. Timing is pure so tests need no pointer.

struct SidebarStepAside: Equatable {
    enum Phase: Equatable {
        case idle
        // Pointer on the usable sidebar; `since` is its last use.
        case watching(since: TimeInterval)
        case steppedAside
    }

    enum Action: Equatable {
        // Nothing to wait for: stepped aside already, or the pointer is off the sidebar.
        case none
        // Check again after this long; a resting pointer sends no events to trigger the check itself.
        case checkAfter(TimeInterval)
        // Unused for the delay: fade out and pass clicks through.
        case stepAside
    }

    // Timer callbacks can land a little early relative to the recorded start.
    static let timingTolerance: TimeInterval = 0.01
    // A resting hand still drifts the pointer a few points; movement within this distance
    // of the last counted move is tremor, not use.
    static let jitterTolerance: CGFloat = 4

    private(set) var phase: Phase = .idle
    // Where the last counted move ended; nil until the first move while watching.
    private var restPoint: CGPoint?

    var isSteppedAside: Bool { phase == .steppedAside }

    // `inUse` covers state the pointer path sees directly, such as an open window list.
    mutating func update(pointerInside: Bool, inUse: Bool, now: TimeInterval, delay: TimeInterval) -> Action {
        // Leaving returns the sidebar to its normal look.
        guard pointerInside else {
            reset()
            return .none
        }
        switch phase {
        case .idle:
            phase = .watching(since: now)
            return .checkAfter(delay)
        case .watching(let since):
            if inUse {
                phase = .watching(since: now)
                return .checkAfter(delay)
            }
            let remaining = since + delay - now
            guard remaining <= Self.timingTolerance else { return .checkAfter(remaining) }
            phase = .steppedAside
            return .stepAside
        case .steppedAside:
            // Stay out of the way until the pointer leaves, even while it moves or clicks underneath.
            return .none
        }
    }

    // Clicks, drags and scrolls on the usable sidebar restart the wait.
    mutating func pointerInteracted(now: TimeInterval) {
        if case .watching = phase { phase = .watching(since: now) }
    }

    // A plain move restarts the wait only once it travels past `jitterTolerance`, so tremor
    // never counts; slow drift still adds up because the rest point stays put until then.
    mutating func pointerMoved(to point: CGPoint, now: TimeInterval) {
        guard case .watching = phase else { return }
        if let restPoint, hypot(point.x - restPoint.x, point.y - restPoint.y) <= Self.jitterTolerance { return }
        restPoint = point
        phase = .watching(since: now)
    }

    mutating func reset() {
        phase = .idle
        restPoint = nil
    }
}

//// The controller owns the fade and the timer; this type only decides when each happens.
//////////////////
