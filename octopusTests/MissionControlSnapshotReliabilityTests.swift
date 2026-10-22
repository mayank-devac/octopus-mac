import AppKit
import Testing
@testable import octopus

struct MissionControlSnapshotReliabilityTests {
    @Test func finderHelpersRequirePositiveEvidenceAndRealFolderWindowsRemain() {
        func helper(title: String?, close: Bool?, parent: Bool = false) -> Bool {
            SidebarWindowPolicy.isWindowHelper(bundleIdentifier: "com.apple.finder", title: title,
                applicationTitle: "Finder", subrole: "AXStandardWindow", hasCloseButton: close,
                parentIsWindow: parent, bounds: CGRect(x: 0, y: 0, width: 600, height: 400), minimized: false)
        }
        #expect(helper(title: "Finder", close: false))
        #expect(helper(title: "", close: false))
        #expect(helper(title: "Downloads", close: false, parent: true))
        #expect(!helper(title: "Finder", close: true))
        #expect(!helper(title: "Downloads", close: true))
        #expect(!helper(title: "Finder", close: nil))
        #expect(!helper(title: nil, close: false))
        #expect(!helper(title: "Downloads", close: false))
    }

    private let desktop = SidebarDesktop(id: 1, order: 0, number: 1, displayIdentifier: "primary")
    private let screen = MissionControlScreen(id: "primary", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))

    private func record(_ id: CGWindowID = 1) -> MissionControlWindowRecord {
        MissionControlWindowRecord(id: SidebarWindowID(pid: 100, windowID: id),
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300), desktopIDs: [1],
            isMinimized: false)
    }

    private func snapshot(_ item: MissionControlWindowRecord) -> MissionControlSnapshot {
        MissionControlSnapshot.make(
            catalog: SidebarSpaceReader.Catalog(desktops: [desktop], activeIDs: [desktop.id]),
            applications: [MissionControlApplication(pid: 100, name: "Test app", icon: nil)],
            records: [item], screens: [screen], ownPID: 999)
    }

    @Test func confirmedInvalidAXIdentityIsRemovedWithoutRemovingOtherWindows() {
        var records = [
            record(1),
            record(2)
        ].reduce(into: [SidebarWindowID: MissionControlWindowRecord]()) { $0[$1.id] = $1 }
        MissionControlSnapshotReader.removeInvalidatedRecords([1], pid: 100, from: &records)
        #expect(Set(records.keys) == [SidebarWindowID(pid: 100, windowID: 2)])
    }

    @Test func distinctWindowsOfTheSameAppKeepTheirOwnIdentities() {
        let item = record()
        let data = snapshot(item)
        #expect(data.windows.count == 1)
        #expect(data.windows[0].id == item.id)
        let twoWindows = MissionControlSnapshot.make(
            catalog: SidebarSpaceReader.Catalog(desktops: [desktop], activeIDs: [desktop.id]),
            applications: [MissionControlApplication(pid: 100, name: "Finder", icon: nil)],
            records: [record(1), record(2), record(1)], screens: [screen], ownPID: 999)
        #expect(Set(twoWindows.windows.map(\.id)) == [record(1).id, record(2).id])
    }

    @Test func reopenCacheStillExpiresAfterTwoSeconds() {
        var state = MissionControlSnapshotState()
        let data = snapshot(record())
        let accepted = state.receive(data, generation: state.generation, now: 100)
        #expect(accepted)
        #expect(state.freshSnapshot(at: 101)?.windows.count == 1)
        #expect(state.freshSnapshot(at: 102) == nil)
    }

    @Test func cacheExpiryDuringRefreshDoesNotCloseAnAlreadyDisplayedMap() {
        var state = MissionControlSnapshotState()
        let cached = snapshot(record(1))
        _ = state.receive(cached, generation: state.generation, now: 10)
        state.beginPresentation(at: 11.9)
        #expect(state.displayedSnapshot?.windows.first?.id == record(1).id)
        #expect(state.freshSnapshot(at: 12.1) == nil)
        let failed = state.receive(nil, generation: state.generation, now: 12.2)
        #expect(!failed && state.displayedSnapshot?.windows.first?.id == record(1).id)

        _ = state.receive(snapshot(record(2)), generation: state.generation, now: 13)
        #expect(state.displayedSnapshot?.windows.first?.id == record(2).id)
        state.endPresentation()
        state.beginPresentation(at: 16)
        #expect(state.displayedSnapshot == nil)
        _ = state.receive(cached, generation: state.generation, now: 16.1)
        #expect(state.displayedSnapshot?.windows.first?.id == record(1).id)
    }
}
