import Foundation
import Testing
@testable import octopus

////////////////////
//// Sidebar app menu items, grid navigation, pinned apps and the Control-click binding
/// Pure planning only; the menu's hover, auto-close and animation need the real app.

struct SidebarAppMenuTests {
    private func context(running: Bool = true, target: Bool = true, desktops: [SidebarAppMenuDesktop] = [],
                         pinned: Bool = false) -> SidebarAppMenuContext {
        let window = SidebarWindowID(pid: 1, windowID: 9)
        return SidebarAppMenuContext(
            title: "App", isRunning: running, isHidden: false, isPinned: pinned, canPin: true, hasBundleURL: true,
            windows: running ? [SidebarAppMenuWindow(id: window, title: "Doc", isMinimized: false)] : [],
            targetWindow: running && target ? window : nil, canCloseTarget: running && target, desktops: desktops)
    }

    private func commands(_ sections: [SidebarAppMenuSection]) -> [SidebarAppMenuCommand] {
        sections.flatMap(\.items).map(\.command)
    }

    @Test func runningAppOffersWindowsSnapMoveActionsAndQuitLast() {
        let sections = SidebarAppMenuCatalogue.sections(for: context(desktops: [SidebarAppMenuDesktop(id: 7, number: 2)]))
        #expect(sections.map(\.id) == ["windows", "snap", "desktops", "actions", "quit"])
        #expect(commands(sections).contains(.moveToDesktop(7)))
        #expect(commands(sections).last == .quit)
        #expect(sections.last?.items.first?.isDestructive == true)
    }

    @Test func notRunningPinnedAppOffersOpenAndUnpinWithoutQuitOrSnap() {
        let all = commands(SidebarAppMenuCatalogue.sections(for: context(running: false, pinned: true)))
        #expect(all == [.open, .togglePin, .showInFinder])
    }

    @Test func noTargetWindowHidesSnapAndClose() {
        let all = commands(SidebarAppMenuCatalogue.sections(for: context(target: false)))
        #expect(!all.contains(.snap(.left)))
        #expect(!all.contains(.closeWindow))
    }

    @Test func gridNavigationWrapsRowsAndWalksChips() {
        let grid: [[Int]] = [[1], [2, 3, 4], [5]]
        #expect(MenuGridNavigator.move(nil, .down, in: grid) == 1)
        #expect(MenuGridNavigator.move(nil, .up, in: grid) == 5)
        #expect(MenuGridNavigator.move(5, .down, in: grid) == 1)
        #expect(MenuGridNavigator.move(2, .right, in: grid) == 3)
        #expect(MenuGridNavigator.move(4, .right, in: grid) == 4)
        #expect(MenuGridNavigator.move(4, .down, in: grid) == 5)
    }

    @Test func pinnedPlaceholdersSkipRunningAppsAndUseNegativeIDs() {
        #expect(SidebarPinnedApps.toggling("a", in: ["a", "b"]) == ["b"])
        #expect(SidebarPinnedApps.toggling("c", in: ["a"]) == ["a", "c"])
        #expect(SidebarPinnedApps.placeholderIdentifiers(pinned: ["a", "b", "a", "c"], running: ["b"]) == ["a", "c"])
        #expect(SidebarPinnedApps.placeholderPID(at: 0) == -1)
    }

    @MainActor @Test func appMenuClickCannotAlsoBeBoundToHideOrMinimise() throws {
        let name = "SidebarAppMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MouseShortcutStore(defaults: defaults)
        #expect(store.appMenuShortcut == MouseShortcut(button: 0, modifiers: .control))
        #expect(store.assign(store.appMenuShortcut, to: .hide) == ShortcutPreferenceStrings.appMenuConflict)
        store.setAppMenuButton(.right)
        #expect(MouseShortcutStore(defaults: defaults).appMenuShortcut == MouseShortcut(button: 1, modifiers: .control))
        #expect(store.assign(MouseShortcut(button: 0, modifiers: .control), to: .minimize) == nil)
    }
}

//////////////////
