import CoreGraphics
import Foundation
import Testing
@testable import octopus

////////////////////
//// Window menu content, keyboard navigation and recent-app history
/// Pure planning only; pointer, hover, animation and panel behaviour need the real app.

struct WindowMenuTests {
    private let installed: (String) -> WindowMenuInstalledApp? = { identifier in
        WindowMenuInstalledApp(title: identifier.uppercased(), bundleURL: URL(fileURLWithPath: "/Applications/\(identifier).app"))
    }

    private func runningApp(_ pid: pid_t, _ bundle: String?, windows: [CGWindowID]) -> WindowMenuRunningApp {
        WindowMenuRunningApp(pid: pid, bundleIdentifier: bundle, title: bundle ?? "App \(pid)", bundleURL: nil,
                             windows: windows.map {
                                 WindowMenuWindowSnapshot(windowID: $0, title: "W\($0)", desktopLabel: nil, isMinimized: false, canClose: true)
                             })
    }

    private func workspace(_ bundles: [String]) -> WindowMenuWorkspace {
        WindowMenuWorkspace(id: UUID(), label: "1", name: "One", bundleIdentifiers: bundles)
    }

    @Test func workspacesListNumberedProfilesFirstAndFlattenMultiAppSlots() {
        var second = Profile(name: "Second", profileNumber: 2)
        second.bindings[0] = .workspace(Workspace(name: "Pair", bundleIdentifiers: ["b", "c"]))
        second.bindings[3] = .application("b")
        let first = Profile(name: "first", profileNumber: 1)
        let unnumbered = Profile(name: "  zed ")
        let workspaces = WindowMenuCatalogue.workspaces(from: [unnumbered, second, first])
        #expect(workspaces.map(\.label) == ["1", "2", "Z"])
        #expect(workspaces[1].bundleIdentifiers == ["b", "c"])
    }

    @Test func contentKeepsSlotOrderAddsHoveredAppAndGroupsWindowsByApp() {
        let content = WindowMenuCatalogue.content(
            workspaces: [workspace(["a", "missing", "b"])], selectedWorkspaceID: nil,
            running: [runningApp(10, "b", windows: [3]), runningApp(20, "x", windows: [7]), runningApp(30, "a", windows: [1, 2])],
            focusPID: 20, installed: { $0 == "missing" ? installed($0) : nil })
        // The hovered app outside the workspace leads; the not-running bound app stays, dimmed.
        #expect(content.apps.map(\.id) == ["x", "a", "missing", "b"])
        #expect(content.apps[2].isRunning == false)
        #expect(content.windows.map(\.id.windowID) == [7, 1, 2, 3])
    }

    @Test func emptyWorkspaceFallsBackToRunningAppsWithWindows() {
        let content = WindowMenuCatalogue.content(
            workspaces: [], selectedWorkspaceID: nil,
            running: [runningApp(1, "a", windows: []), runningApp(2, nil, windows: [5])],
            focusPID: nil, installed: installed)
        #expect(content.apps.map(\.id) == ["pid:2"])
    }

    @Test func recentAppsSkipRunningAppsAndStopAtTheLimit() {
        let content = WindowMenuCatalogue.content(
            workspaces: [], selectedWorkspaceID: nil, running: [runningApp(1, "a", windows: [1])], focusPID: nil,
            recentBundleIdentifiers: ["a", "b", "c", "d"], recentLimit: 2, installed: installed)
        #expect(content.recentApps.map(\.id) == ["b", "c"])
    }

    @Test func arrowsMoveBetweenStripsListAndAppGroups() {
        let space = workspace(["a", "b"])
        var content = WindowMenuCatalogue.content(
            workspaces: [space, workspace([])], selectedWorkspaceID: space.id,
            running: [runningApp(1, "a", windows: [1, 2]), runningApp(2, "b", windows: [3])],
            focusPID: nil, recentBundleIdentifiers: ["r"], installed: installed)
        let first = WindowMenuTarget.window(SidebarWindowID(pid: 1, windowID: 1))
        let third = WindowMenuTarget.window(SidebarWindowID(pid: 2, windowID: 3))
        #expect(WindowMenuNavigator.move(nil, .down, in: content) == first)
        #expect(WindowMenuNavigator.move(first, .right, in: content) == third)
        #expect(WindowMenuNavigator.move(third, .left, in: content) == first)
        #expect(WindowMenuNavigator.move(first, .up, in: content) == .app("a"))
        #expect(WindowMenuNavigator.move(.app("a"), .left, in: content) == .workspace(space.id))
        #expect(WindowMenuNavigator.move(.app("b"), .up, in: content) == .recent("r"))
        #expect(WindowMenuNavigator.move(.recent("r"), .down, in: content) == .app("a"))
        #expect(WindowMenuNavigator.move(.app("b"), .down, in: content) == third)
        // Edges hold focus instead of wrapping.
        #expect(WindowMenuNavigator.move(third, .down, in: content) == third)
        content.workspaces = [space]
        #expect(WindowMenuNavigator.move(.app("a"), .left, in: content) == .app("a"))
    }

    @Test func recentHistoryMovesUsedAppToFrontAndCaps() {
        #expect(RecentAppsStore.recording("b", in: ["a", "b", "c"], capacity: 3) == ["b", "a", "c"])
        #expect(RecentAppsStore.recording("d", in: ["a", "b", "c"], capacity: 3) == ["d", "a", "b"])
    }

    @Test func cardHeightMatchesRowsAndCapsLongLists() {
        var content = WindowMenuContent()
        let base = WindowMenuLayout.cardSize(content: content, isCenter: false, status: .ready).height
        content.windows = (1...3).map {
            WindowMenuWindow(id: SidebarWindowID(pid: 1, windowID: $0), appID: "a", title: "", desktopLabel: nil,
                             isMinimized: false, canClose: true)
        }
        let three = WindowMenuLayout.cardSize(content: content, isCenter: false, status: .ready).height
        #expect(three - base == 3 * WindowMenuMetrics.windowRowHeight - WindowMenuMetrics.emptyListHeight)
        #expect(WindowMenuLayout.hasMoreWindows(WindowMenuMetrics.sidebarMaximumRows + 1, isCenter: false))
        #expect(!WindowMenuLayout.hasMoreWindows(WindowMenuMetrics.sidebarMaximumRows, isCenter: false))
    }
}

//////////////////
