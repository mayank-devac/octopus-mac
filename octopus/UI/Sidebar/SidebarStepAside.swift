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
        case none
        // Check again after this long; a resting pointer sends no events to trigger the check itself.
        case checkAfter(TimeInterval)
        // Unused for the delay: fade out and pass clicks through.
        case stepAside
        // Pointer left: stop waiting and return to the normal look.
        case restore
    }

    // Timer callbacks can land a little early relative to the recorded start.
    static let timingTolerance: TimeInterval = 0.01

    private(set) var phase: Phase = .idle

    var isSteppedAside: Bool { phase == .steppedAside }

    // `inUse` covers state the pointer path sees directly, such as an open window list.
    mutating func update(pointerInside: Bool, inUse: Bool, now: TimeInterval, delay: TimeInterval) -> Action {
        guard pointerInside else {
            let wasActive = phase != .idle
            phase = .idle
            return wasActive ? .restore : .none
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

    // Movement, clicks and scrolls on the usable sidebar restart the wait.
    mutating func pointerInteracted(now: TimeInterval) {
        if case .watching = phase { phase = .watching(since: now) }
    }

    mutating func reset() { phase = .idle }
}

//// The controller owns the fade and the timer; this type only decides when each happens.
//////////////////
