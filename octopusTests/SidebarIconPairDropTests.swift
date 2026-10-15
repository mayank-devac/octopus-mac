import AppKit
import Testing
@testable import octopus

struct SidebarIconPairDropTests {
    @Test func centreGroupsInsteadOfKeepingAnEarlierSideWhenGroupingIsEnabled() {
        let intent = SidebarIconPairDrop.resolve(at: CGPoint(x: 120, y: 220), source: source, sourceVisible: true,
            targets: [icon(target)], previousTarget: target, previousDirection: .left, tabGrouping: true)
        guard case .tabs(let chosen) = intent else { Issue.record("Centre must select tab grouping"); return }
        #expect(chosen.window == target)
        let legacy = SidebarIconPairDrop.resolve(at: CGPoint(x: 120, y: 220), source: source, sourceVisible: true,
            targets: [icon(target)], previousTarget: target, previousDirection: .left, tabGrouping: false)
        guard case .pair(_, let direction) = legacy else { Issue.record("Disabled grouping retains the pair route"); return }
        #expect(direction == .left)
    }

    @Test func edgesKeepAllFourSnapDirectionsWithCentreGroupingEnabled() {
        let points: [(CGPoint, PairDropDirection)] = [(CGPoint(x: 103, y: 220), .left),
            (CGPoint(x: 137, y: 220), .right), (CGPoint(x: 120, y: 237), .top), (CGPoint(x: 120, y: 203), .bottom)]
        for (point, expected) in points {
            let intent = SidebarIconPairDrop.resolve(at: point, source: source, sourceVisible: true,
                targets: [icon(target)], previousTarget: nil, previousDirection: nil, tabGrouping: true)
            guard case .pair(let chosen, let direction) = intent else { Issue.record("An icon edge must keep side snapping"); continue }
            #expect(chosen.window == target && direction == expected)
        }
    }

    @Test func centreCannotGroupWithItselfOrFallThroughAReservedClosedIcon() {
        let point = CGPoint(x: 120, y: 220)
        let selfDrop = SidebarIconPairDrop.resolve(at: point, source: source, sourceVisible: true,
            targets: [icon(source)], previousTarget: nil, previousDirection: nil, tabGrouping: true)
        guard case .blocked = selfDrop else { Issue.record("Self grouping must be blocked"); return }
        let closed = SidebarIconPairDrop.resolve(at: point, source: source, sourceVisible: true,
            targets: [icon(target, visible: false, reserved: true)], previousTarget: nil, previousDirection: nil, tabGrouping: true)
        guard case .blocked = closed else { Issue.record("A closed centre target must not become a Desktop transfer"); return }
    }
    private let source = SidebarWindowID(pid: 42, windowID: 1)
    private let target = SidebarWindowID(pid: 43, windowID: 2)
    private let frame = CGRect(x: 100, y: 200, width: 40, height: 40)

    private func icon(_ id: SidebarWindowID, visible: Bool = true, reserved: Bool = false) -> SidebarIconPairTarget {
        SidebarIconPairTarget(ownerID: UUID(), entryID: SidebarEntryID(pid: id.pid, desktopID: 7),
            window: id, title: "Target", frame: frame, isVisible: visible, reservesPairDrop: reserved)
    }

    @Test func fourSidesChooseHalvesAndCentreKeepsOnlyAnExistingChoice() {
        #expect(PairDropDirection.choose(at: CGPoint(x: 103, y: 220), in: frame, previous: nil) == .left)
        #expect(PairDropDirection.choose(at: CGPoint(x: 137, y: 220), in: frame, previous: nil) == .right)
        #expect(PairDropDirection.choose(at: CGPoint(x: 120, y: 237), in: frame, previous: nil) == .top)
        #expect(PairDropDirection.choose(at: CGPoint(x: 120, y: 203), in: frame, previous: nil) == .bottom)
        #expect(PairDropDirection.choose(at: CGPoint(x: 120, y: 220), in: frame, previous: nil) == nil)
        #expect(PairDropDirection.choose(at: CGPoint(x: 120, y: 220), in: frame, previous: .left) == .left)
        #expect(PairDropDirection.choose(at: CGPoint(x: 135, y: 235), in: frame, previous: .top) == .top)
        #expect(PairDropDirection.choose(at: CGPoint(x: 90, y: 220), in: frame, previous: .left) == nil)
    }

    @Test func eligibleIconTakesPriorityAndSelfDropCannotBecomeTransfer() {
        let point = CGPoint(x: 103, y: 220)
        let intent = SidebarIconPairDrop.resolve(at: point, source: source, sourceVisible: true,
            targets: [icon(target)], previousTarget: nil, previousDirection: nil)
        guard case .pair(let chosen, let direction) = intent else { Issue.record("Visible icon must choose pair intent"); return }
        #expect(chosen.window == target && direction == .left)
        let selfDrop = SidebarIconPairDrop.resolve(at: point, source: source, sourceVisible: true,
            targets: [icon(source)], previousTarget: nil, previousDirection: nil)
        guard case .blocked = selfDrop else { Issue.record("Self drop must not fall through to transfer"); return }
    }

    @Test func inactiveIconsKeepTransferRoutingAndAClosedPairTargetBlocksFallback() {
        let point = CGPoint(x: 103, y: 220)
        let inactive = SidebarIconPairDrop.resolve(at: point, source: source, sourceVisible: true,
            targets: [icon(target, visible: false)], previousTarget: nil, previousDirection: nil)
        guard case .other = inactive else { Issue.record("Inactive Desktop retains the transfer route"); return }
        let closed = SidebarIconPairDrop.resolve(at: point, source: source, sourceVisible: true,
            targets: [icon(target, visible: false)], previousTarget: target, previousDirection: .left)
        guard case .blocked = closed else { Issue.record("A rejected pair must not become transfer"); return }
        let stillClosed = SidebarIconPairDrop.resolve(at: point, source: source, sourceVisible: true,
            targets: [icon(target, visible: false, reserved: true)], previousTarget: nil, previousDirection: nil)
        guard case .blocked = stillClosed else { Issue.record("Repeated updates must keep the rejected icon reserved"); return }
        let hiddenSource = SidebarIconPairDrop.resolve(at: point, source: source, sourceVisible: false,
            targets: [icon(target)], previousTarget: nil, previousDirection: nil)
        guard case .other = hiddenSource else { Issue.record("A non-visible source cannot pair"); return }
    }

    @Test func changingTargetsDoesNotCarryAHiddenDirectionIntoTheCentre() {
        let intent = SidebarIconPairDrop.resolve(at: CGPoint(x: 120, y: 220), source: source, sourceVisible: true,
            targets: [icon(target)], previousTarget: SidebarWindowID(pid: 44, windowID: 3), previousDirection: .top)
        guard case .pair(_, let direction) = intent else { Issue.record("Centre reserves the visible icon"); return }
        #expect(direction == nil)
    }

    @Test func desktopTransferEligibilityRemainsSeparateFromPairDirection() {
        let a = SidebarDesktop(id: 1, order: 0, number: 1, displayIdentifier: "display")
        let b = SidebarDesktop(id: 2, order: 1, number: 2, displayIdentifier: "display")
        let other = SidebarDesktop(id: 3, order: 2, number: 3, displayIdentifier: "other")
        #expect(SidebarDesktopTransferPolicy.allows(source: a, destination: b))
        #expect(!SidebarDesktopTransferPolicy.allows(source: a, destination: a))
        #expect(!SidebarDesktopTransferPolicy.allows(source: a, destination: other))
    }
}
