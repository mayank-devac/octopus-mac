import AppKit
import Testing
@testable import octopus

struct MissionControlSnapshotReliabilityTests {
    private let desktop = SidebarDesktop(id: 1, order: 0, number: 1, displayIdentifier: "primary")
    private let screen = MissionControlScreen(id: "primary", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))

    private func record(verifiedAt: TimeInterval = 10) -> MissionControlWindowRecord {
        MissionControlWindowRecord(id: SidebarWindowID(pid: 100, windowID: 1),
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300), desktopIDs: [1],
            isMinimized: false, verifiedAt: verifiedAt)
    }

    private func snapshot(_ item: MissionControlWindowRecord) -> MissionControlSnapshot {
        MissionControlSnapshot.make(
            catalog: SidebarSpaceReader.Catalog(desktops: [desktop], activeIDs: [desktop.id]),
            applications: [MissionControlApplication(pid: 100, name: "Test app", icon: nil)],
            records: [item], screens: [screen], ownPID: 999)
    }

    @Test func partialMembershipDoesNotPretendAnUnreadWindowIsAbsent() {
        let verified = SidebarSpaceReader.WindowMembershipResult(state: .verified([desktop]))
        guard case .verified(let members) = verified.state else {
            Issue.record("a successful membership must be verified")
            return
        }
        #expect(members == [desktop])
        guard case .failed = SidebarSpaceReader.WindowMembershipResult(state: .failed).state else {
            Issue.record("a failed membership must not become an empty membership")
            return
        }
        guard case .notRead = SidebarSpaceReader.WindowMembershipResult(state: .notRead).state else {
            Issue.record("an unattempted membership must remain notRead")
            return
        }
    }

    @Test func staleVerifiedRecordSurvivesActiveSnapshotConstruction() {
        let item = record(verifiedAt: 1)
        let data = snapshot(item)
        #expect(data.windows.count == 1)
        #expect(data.windows[0].id == item.id && data.windows[0].verifiedAt == 1)
    }

    @Test func reopenCacheStillExpiresAfterTwoSeconds() {
        var state = MissionControlSnapshotState()
        let data = snapshot(record(verifiedAt: 1))
        #expect(state.receive(data, generation: state.generation, now: 100))
        #expect(state.freshSnapshot(at: 101)?.windows.count == 1)
        #expect(state.freshSnapshot(at: 102) == nil)
    }
}
