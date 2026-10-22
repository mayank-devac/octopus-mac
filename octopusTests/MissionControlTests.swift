import AppKit
import Testing
@testable import octopus

struct MissionControlTests {
    private struct Element {
        let id: String
        var children: [Element] = []
    }

    private func reading(_ children: [Element], owner: MissionControlAXProbe.Owner) -> MissionControlReading {
        MissionControlAXProbe.classify(root: Element(id: "root", children: children), owner: owner,
                                       children: { $0.children }, identifier: { $0.id })
    }

    @Test func recognisesDockAndWindowManagerTrees() {
        let display = Element(id: "mc.display", children: [Element(id: "mc.spaces")])
        #expect(reading([Element(id: "mc", children: [display])], owner: .dock) == .visible)
        #expect(reading([display], owner: .windowManager) == .visible)
    }

    @Test func ignoresAppExposeAndEmptyDockStub() {
        #expect(reading([Element(id: "mc")], owner: .dock) == .hidden)
        #expect(reading([Element(id: "appexpose", children: [Element(id: "appexpose.display")])],
                        owner: .dock) == .hidden)
        #expect(reading([Element(id: "appexpose.display")], owner: .windowManager) == .hidden)
        #expect(reading([Element(id: "mc.display")], owner: .windowManager) == .hidden)
    }

    @Test func failedAccessibilityReadIsUnavailable() {
        let result = MissionControlAXProbe.classify(root: Element(id: "root"), owner: .dock,
                                                    children: { _ in nil }, identifier: { $0.id })
        #expect(result == .unavailable)
    }

    @Test func crowdedAccessibilityGroupsStayBoundedAndIncludeTheTrailingSpacesStrip() {
        let ranges = MissionControlAXProbe.childRanges(count: 300, limit: 64)
        #expect(ranges.reduce(0) { $0 + $1.count } == 64)
        #expect(ranges.first?.contains(299) == true)
        #expect(ranges.contains { $0.contains(0) })
        #expect(MissionControlAXProbe.childRanges(count: 0, limit: 64).isEmpty)
    }

    @Test func closingFailureAndStopAllClearVisibility() {
        var state = MissionControlMonitorState()
        state.start()
        let generation = state.generation
        state.receive(.visible, generation: generation)
        #expect(state.isVisible)
        state.receive(.hidden, generation: generation)
        #expect(!state.isVisible)
        state.receive(.visible, generation: generation)
        state.receive(.unavailable, generation: generation)
        #expect(!state.isVisible)
        state.receive(.visible, generation: generation)
        state.stop()
        #expect(!state.isVisible && state.phase == .stopped)
    }

    @Test func lateReadCannotReopenAfterStopOrRestart() {
        var state = MissionControlMonitorState()
        state.start()
        let oldGeneration = state.generation
        state.stop()
        state.receive(.visible, generation: oldGeneration)
        #expect(state.phase == .stopped)
        state.start()
        state.receive(.visible, generation: oldGeneration)
        #expect(!state.isVisible)
        state.receive(.visible, generation: state.generation)
        #expect(state.isVisible)
    }

    @Test func placementFollowsSidebarSideAndPositionWithoutCoveringDesktopStripOrDock() {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: 270, width: 1920, height: 986)
        let available = MissionControlPlacement.availableFrame(screen: screen, visibleFrame: visible)
        let size = CGSize(width: 136, height: 250)
        #expect(available.maxY < screen.maxY - screen.height * 0.2)
        #expect(available.minY > visible.minY)
        let shortScreen = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let shortArea = MissionControlPlacement.availableFrame(screen: shortScreen, visibleFrame: shortScreen)
        #expect(shortArea.maxY <= shortScreen.maxY - 180)
        for side in [SidebarSide.left, .right] {
            for position in [0.0, 0.5, 1.0] {
                let frame = MissionControlPlacement.frame(in: available, size: size, side: side, position: position)
                #expect(available.contains(frame))
                #expect(side == .left ? frame.minX == available.minX : frame.maxX == available.maxX)
                if position == 0 { #expect(frame.maxY == available.maxY) }
                if position == 1 { #expect(frame.minY == available.minY) }
                let collapsed = MissionControlPlacement.collapsed(frame, side: side)
                #expect(collapsed.width == 1 && collapsed.height == frame.height)
                #expect(side == .left ? collapsed.minX == frame.minX : collapsed.maxX == frame.maxX)
            }
        }
    }

    private let primary = MissionControlScreen(id: "primary", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
    private let secondary = MissionControlScreen(id: "secondary", bounds: CGRect(x: -1920, y: -180, width: 1920, height: 1080))

    private func catalog(_ count: Int = 3, display: String = "primary") -> SidebarSpaceReader.Catalog {
        SidebarSpaceReader.Catalog(desktops: (0..<count).map {
            SidebarDesktop(id: UInt64($0 + 1), order: $0, number: $0 + 1, displayIdentifier: display)
        }, activeIDs: [1])
    }

    private func record(_ id: UInt32 = 1, x: CGFloat = 100, y: CGFloat = 100,
                        desktops: Set<UInt64> = [1]) -> MissionControlWindowRecord {
        MissionControlWindowRecord(id: SidebarWindowID(pid: 100, windowID: id),
            bounds: CGRect(x: x, y: y, width: 400, height: 300), desktopIDs: desktops, isMinimized: false)
    }

    private func snapshot(_ records: [MissionControlWindowRecord] = [],
                          catalog: SidebarSpaceReader.Catalog? = nil) -> MissionControlSnapshot {
        MissionControlSnapshot.make(catalog: catalog ?? self.catalog(),
            applications: [MissionControlApplication(pid: 100, name: "Test app", icon: nil)],
            records: records, screens: [primary, secondary], ownPID: 999)
    }

    @Test func filtersMinimizedHiddenOwnUnknownAndInvalidWindows() {
        var minimized = record(2)
        minimized.isMinimized = true
        var unknownState = record(3)
        unknownState.isMinimized = nil
        var unknownDesktop = record(4)
        unknownDesktop.desktopIDs = nil
        var invalid = record(5)
        invalid.bounds = CGRect(x: 0, y: 0, width: 0, height: 100)
        var helper = record(6)
        helper.isStandardWindow = false
        let result = snapshot([record(), minimized, unknownState, unknownDesktop, invalid, helper, record(7, desktops: [99])])
        #expect(result.windows.map(\.id.windowID) == [1])
        let hidden = MissionControlApplication(pid: 100, name: "Hidden", icon: nil, isHidden: true)
        #expect(MissionControlSnapshot.make(catalog: catalog(), applications: [hidden], records: [record()],
            screens: [primary], ownPID: 999).windows.isEmpty)
        let ownApp = MissionControlApplication(pid: 100, name: "Octopus", icon: nil)
        #expect(MissionControlSnapshot.make(catalog: catalog(), applications: [ownApp], records: [record()],
            screens: [primary], ownPID: 100).applications.isEmpty)
    }

    @Test func inactiveDesktopAndRepeatedAppWindowsKeepTheirExactIdentities() {
        let result = snapshot([record(1, desktops: [2]), record(2, desktops: [2])])
        #expect(result.windows.map(\.id.windowID) == [1, 2])
        #expect(result.windows.allSatisfy { $0.desktopIDs == [2] })
        #expect(result.desktops.count == 3 && result.activeIDs == [1])
    }

    @Test func separateAndSharedSpacesRouteUsingTheCorrectScreen() {
        let separate = SidebarSpaceReader.Catalog(desktops: catalog().desktops + [
            SidebarDesktop(id: 4, order: 3, number: 4, displayIdentifier: "secondary")
        ], activeIDs: [1, 4])
        let result = snapshot([record(1), record(2, x: -1800, y: -100, desktops: [4])], catalog: separate)
        #expect(result.desktops(on: "primary").map(\.id) == [1, 2, 3])
        #expect(result.desktops(on: "secondary").map(\.id) == [4])
        #expect(result.windows.map(\.screenID) == ["primary", "secondary"])
        let shared = snapshot([record(1), record(2, x: -1800, y: -100)], catalog: catalog(display: "Main"))
        #expect(shared.desktops(on: "primary") == shared.desktops(on: "secondary"))
        #expect(shared.windows.map(\.screenID) == ["primary", "secondary"])
    }

    @Test func stickyWindowsAppearInEveryApplicableTileAndEmptyDesktopsRemain() throws {
        let result = snapshot([record(desktops: [1, 2, 3])])
        let layout = try #require(MissionControlLayout.make(snapshot: result, screenID: "primary",
            screenSize: primary.bounds.size))
        #expect(layout.tiles.count == 3)
        #expect(layout.tiles.allSatisfy { $0.icons.map(\.windowID.windowID) == [1] })
        let empty = try #require(MissionControlLayout.make(snapshot: snapshot(), screenID: "primary",
            screenSize: primary.bounds.size))
        #expect(empty.tiles.count == 3 && empty.tiles.allSatisfy { $0.icons.isEmpty })
    }

    @Test func fullScreenSpacesRetainOrderAndCanBeActive() throws {
        let displays: [[String: Any]] = [["Display Identifier": "primary", "Spaces": [
            ["ManagedSpaceID": 1, "type": 0], ["ManagedSpaceID": 2, "type": 4], ["ManagedSpaceID": 3, "type": 0]
        ], "Current Space": ["ManagedSpaceID": 2, "type": 4]]]
        let result = SidebarSpaceReader.catalog(from: displays)
        #expect(result.desktops.map(\.id) == [1, 2, 3])
        #expect(result.desktops[1].number == nil && result.activeIDs == [2])
        let layout = try #require(MissionControlLayout.make(
            snapshot: snapshot([record(desktops: [2])], catalog: result), screenID: "primary",
            screenSize: primary.bounds.size))
        #expect(layout.tiles[1].isActive && layout.tiles[1].icons.count == 1)
    }

    @Test func coordinatesUseTopLeftDesktopPositionsAndClampToTile() {
        let screen = secondary.bounds
        let tile = CGSize(width: 112, height: 63)
        let middle = CGRect(x: screen.midX - 100, y: screen.midY - 50, width: 200, height: 100)
        #expect(MissionControlLayout.centre(window: middle, screen: screen, tile: tile, iconSize: 20)
            == CGPoint(x: 56, y: 31.5))
        let outside = CGRect(x: screen.minX - 500, y: screen.minY - 500, width: 10, height: 10)
        #expect(MissionControlLayout.centre(window: outside, screen: screen, tile: tile, iconSize: 20)
            == CGPoint(x: 13, y: 13))
    }

    @Test func collisionsAreSeparatedDeterministicallyAndDenseTilesShrinkIcons() {
        let overlapping = snapshot((1...8).map { record(UInt32($0)) }).windows
        let first = MissionControlLayout.place(windows: overlapping, screen: primary.bounds, tile: CGSize(width: 112, height: 70))
        let reversed = MissionControlLayout.place(windows: Array(overlapping.reversed()), screen: primary.bounds, tile: CGSize(width: 112, height: 70))
        #expect(first == reversed && first.count == 8 && first.allSatisfy { $0.frame.width == 20 })
        for index in first.indices {
            #expect(first[(index + 1)...].allSatisfy { !first[index].frame.intersects($0.frame) })
        }
        let crowded = snapshot((1...40).map { record(UInt32($0)) }).windows
        let small = MissionControlLayout.place(windows: crowded, screen: primary.bounds, tile: CGSize(width: 112, height: 70))
        #expect(small.count == 40 && small.allSatisfy { $0.frame.width == 14 })
        #expect(small.allSatisfy { CGRect(x: 0, y: 0, width: 112, height: 70).contains($0.frame) })
    }

    @Test func desktopGridWrapsAndScalesWithinScreenWithoutChangingAspectRatio() throws {
        let layout = try #require(MissionControlLayout.make(snapshot: snapshot(catalog: catalog(120)),
            screenID: "primary", screenSize: primary.bounds.size))
        #expect(layout.tiles.count == 120 && layout.scale < 1)
        #expect(layout.size.width <= primary.bounds.width * 0.6)
        #expect(layout.size.height <= primary.bounds.height)
        #expect(Set(layout.tiles.map(\.frame.minY)).count > 1)
        #expect(Set(layout.tiles.map(\.frame.minX)).count > 1)
        let tile = try #require(layout.tiles.first)
        #expect(abs(tile.frame.width / tile.frame.height - primary.bounds.width / primary.bounds.height) < 0.001)
        #expect(layout.tiles.allSatisfy { CGRect(origin: .zero, size: layout.size).contains($0.frame) })
    }

    @Test func failedSnapshotReadKeepsLastValidDataAndLateResultsCannotRestoreClosedPanels() {
        var state = MissionControlSnapshotState()
        let initial = snapshot([record()])
        let accepted = state.receive(initial, generation: state.generation)
        #expect(accepted)
        let failed = state.receive(nil, generation: state.generation)
        #expect(!failed && state.snapshot?.windows == initial.windows)
        let oldGeneration = state.generation
        state.reset()
        let late = state.receive(initial, generation: oldGeneration)
        #expect(!late && state.snapshot == nil)
    }

    @Test @MainActor func realMapViewBindsOneAppImagePerWindowWithoutTooltips() throws {
        let image = NSImage(size: CGSize(width: 20, height: 20))
        let app = MissionControlApplication(pid: 100, name: "Test app", icon: image)
        let data = MissionControlSnapshot.make(catalog: catalog(), applications: [app],
            records: [record(1, desktops: [2]), record(2, desktops: [2])], screens: [primary], ownPID: 999)
        let layout = try #require(MissionControlLayout.make(snapshot: data, screenID: "primary",
            screenSize: primary.bounds.size))
        let view = MissionControlView(frame: CGRect(origin: .zero, size: layout.size))
        view.configure(layout: layout, applications: data.applications, side: .right)
        let images = view.subviews.flatMap(\.subviews).compactMap { $0 as? NSImageView }
        #expect(view.subviews.count == 3 && images.count == 2)
        #expect(images.allSatisfy { $0.image === image && $0.toolTip == nil })
    }

    @Test func ordinaryDesktopMapStacksVerticallyAndFitsTheSideArea() throws {
        let available = CGSize(width: 1440, height: 650)
        let layout = try #require(MissionControlLayout.make(snapshot: snapshot(), screenID: "primary",
            screenSize: primary.bounds.size, availableSize: available))
        #expect(layout.tiles.count == 3 && layout.size.height > layout.size.width)
        #expect(Set(layout.tiles.map(\.frame.minX)).count == 1)
        #expect(layout.tiles[0].frame.minY < layout.tiles[1].frame.minY)
        #expect(layout.tiles[1].frame.minY < layout.tiles[2].frame.minY)
        #expect(layout.size.height <= available.height)
        let limited = try #require(MissionControlLayout.make(snapshot: snapshot(catalog: catalog(40)),
            screenID: "primary", screenSize: primary.bounds.size, availableSize: CGSize(width: 300, height: 400)))
        #expect(limited.size.width <= 300 && limited.size.height <= 400)
    }
}
