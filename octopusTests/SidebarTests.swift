import AppKit
import Combine
import class SwiftUI.NSHostingView
import Testing
@testable import octopus

struct SidebarTests {
    @MainActor @Test func currentDisplayFiltersMenusAndTargetsWithoutChangingDesktopScope() throws {
        let running = NSRunningApplication.current
        let app = Application(running)
        let pid = running.processIdentifier
        let first = SidebarDesktop(id: 101, order: 0, number: 1, displayIdentifier: "A")
        let second = SidebarDesktop(id: 102, order: 1, number: 2, displayIdentifier: "A")
        let other = SidebarDesktop(id: 201, order: 2, number: 3, displayIdentifier: "B")
        func window(_ id: CGWindowID) -> Window {
            let window = Window(AXUIElementCreateApplication(pid), app, cachedTitle: "Window \(id)")
            window.cgWindowID = id
            return window
        }
        let outside = SidebarWindowID(pid: pid, windowID: 20)
        let entry = SidebarEntry(pid: pid, application: app, windows: [window(10), window(11), window(20), window(30)],
            preferredID: outside, focusedID: outside, windowStates: [
                10: SidebarWindowState(isMinimized: false, canMinimize: true, desktops: [first], displayIdentifier: "A"),
                11: SidebarWindowState(isMinimized: true, canMinimize: true, isOnScreen: false,
                                       desktops: [second], displayIdentifier: "A"),
                20: SidebarWindowState(isMinimized: false, canMinimize: true, desktops: [other], displayIdentifier: "B"),
                30: SidebarWindowState(isMinimized: false, canMinimize: true)
            ])
        for scope in SidebarDesktopScope.allCases {
            let filtered = SidebarWindowInventory.entries(for: [running], windowEntries: [entry],
                                                         scope: scope, displayIdentifier: "A")
            #expect(filtered.flatMap(\.windows).compactMap(\.cgWindowID).sorted() == [10, 11])
            #expect(filtered.allSatisfy { $0.focusedID == nil && $0.preferredID != outside })
            #expect(filtered.allSatisfy { $0.windowStates[20] == nil && $0.windowStates[30] == nil })
            #expect(filtered.contains { $0.windowStates[11]?.isMinimized == true })
            #expect(filtered.count == (scope == .allDesktops ? 2 : 1))
        }
        let all = SidebarWindowInventory.entries(for: [running], windowEntries: [entry], scope: .allDesktops)
        #expect(all.flatMap(\.windows).compactMap(\.cgWindowID).sorted() == [10, 11, 20, 30])
        #expect(SidebarWindowInventory.entries(for: [running], windowEntries: [], scope: .allDesktops,
                                              displayIdentifier: "A").isEmpty)
        #expect(SidebarWindowInventory.entries(for: [running], windowEntries: [entry], scope: .allDesktops,
                                              displayIdentifier: "disconnected").isEmpty)
        let selected = try #require(SidebarWindowInventory.entries(for: [running], windowEntries: [entry],
            scope: .allDesktops, displayIdentifier: "B").first)
        #expect(selected.windows.compactMap(\.cgWindowID) == [20])
        #expect(!selected.hasOtherWindows)
        var multipleMemberships = entry
        multipleMemberships.windowStates[20]?.desktops = [first, other]
        let onB = SidebarWindowInventory.entries(for: [running], windowEntries: [multipleMemberships],
                                                scope: .allDesktops, displayIdentifier: "B")
        #expect(onB.count == 1 && onB.first?.desktop == other)
    }

    @Test func displayMembershipHandlesStaleBoundsSharedSpacesAndSpanningWindows() {
        let frames = ["A": CGRect(x: 0, y: 0, width: 1000, height: 800),
                      "B": CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        let desktop = SidebarDesktop(id: 101, order: 0, number: 1, displayIdentifier: "A")
        let onB = CGRect(x: 1200, y: 30, width: 400, height: 300)
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [desktop], bounds: onB, displayFrames: frames) == "A")
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [desktop], bounds: nil, displayFrames: frames) == "A")
        let shared = SidebarDesktop(id: 101, order: 0, number: 1, displayIdentifier: "Main")
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [shared], bounds: onB, displayFrames: frames) == "B")
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [], bounds: onB, displayFrames: frames) == "B")
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [],
            bounds: CGRect(x: 900, y: 30, width: 500, height: 300), displayFrames: frames) == "B")
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [],
            bounds: CGRect(x: -500, y: -500, width: 100, height: 100), displayFrames: frames) == nil)
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [], bounds: nil, displayFrames: frames) == nil)
    }

    @Test func displayFilterLoadsOlderProfilesWithoutResettingTheirPreferences() throws {
        let suite = "SidebarDisplayScopeMigration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var original = SidebarConfiguration.factoryDefaults
        original.enabled = false
        original.side = .left
        original.position = 0.25
        original.desktopScope = .visibleDesktops
        original.displayScope = .currentDisplay
        original.snapDistance = 460
        SidebarSettings.save(original, for: "A", name: "A", in: defaults)
        #expect(SidebarSettings.configuration(for: "A", in: defaults) == original)
        let encoded = try JSONEncoder().encode(SidebarDisplayPreference(name: "A", configuration: original))
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var configuration = try #require(json["configuration"] as? [String: Any])
        configuration.removeValue(forKey: "displayScope")
        json["configuration"] = configuration
        defaults.set(["A": try JSONSerialization.data(withJSONObject: json)], forKey: SidebarSettings.displayPreferencesKey)
        original.displayScope = .allDisplays
        #expect(SidebarSettings.configuration(for: "A", in: defaults) == original)
        #expect(SidebarDisplayScope.saved("unknown") == .allDisplays)
        #expect(SidebarConfiguration.factoryDefaults.displayScope == .allDisplays)
    }

    @Test func displayPreferencesInheritOnceAndRemainIndependentAcrossRestarts() throws {
        let suite = "SidebarDisplays-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("left", forKey: "sidebarSide")
        defaults.set(0.25, forKey: "sidebarPosition")
        defaults.set("hide", forKey: SidebarSettings.idleBehaviorKey)
        defaults.set(false, forKey: "sidebarShowSingleWindowMenu")
        defaults.set(12.0, forKey: "sidebarAppSpacing")
        defaults.set(14.0, forKey: "sidebarFontSize")
        defaults.set(2.0, forKey: "sidebarShadowOpacity")
        defaults.set(400.0, forKey: "sidebarSnapDistance")
        let original = SidebarConfiguration(defaults: defaults)
        #expect(!defaults.bool(forKey: SidebarSettings.multiDisplayKey))
        SidebarSettings.rememberDisplay(id: "A", name: "Same name", in: defaults)
        SidebarSettings.rememberDisplay(id: "B", name: "Same name", in: defaults)
        #expect(SidebarSettings.configuration(for: "A", in: defaults) == original)
        #expect(SidebarSettings.configuration(for: "B", in: defaults) == original)

        var changed = original
        changed.enabled = false
        changed.desktopScope = .visibleDesktops
        changed.side = .right
        changed.position = 0.75
        changed.idleBehavior = .stayVisible
        changed.showSingleWindowMenu = true
        changed.appSpacing = 1
        changed.fontSize = 9
        changed.shadowOpacity = 0
        changed.snapDistance = 20
        SidebarSettings.save(changed, for: "A", name: "Same name", in: defaults)
        let restarted = try #require(UserDefaults(suiteName: suite))
        SidebarSettings.rememberDisplay(id: "A", name: "Renamed display", in: restarted)
        #expect(SidebarSettings.configuration(for: "A", in: restarted) == changed)
        #expect(SidebarSettings.configuration(for: "B", in: restarted) == original)
        #expect(SidebarSettings.configuration(for: nil, in: restarted) == original)
        #expect(SidebarSettings.displayPreferences(in: restarted)["A"]?.name == "Renamed display")
        // An unchanged reconnect should not rewrite preferences and trigger another refresh.
        let saved = restarted.dictionary(forKey: SidebarSettings.displayPreferencesKey)?["A"] as? Data
        SidebarSettings.rememberDisplay(id: "A", name: "Renamed display", in: restarted)
        #expect(restarted.dictionary(forKey: SidebarSettings.displayPreferencesKey)?["A"] as? Data == saved)

        // Reset uses factory defaults, not the customized single-sidebar settings.
        let factory = SidebarConfiguration.factoryDefaults
        #expect(factory.enabled && factory.desktopScope == .allDesktops && factory.side == .right)
        #expect(factory.position == 0.5 && factory.idleBehavior == .fade && factory.showSingleWindowMenu)
        #expect(factory.appSpacing == SidebarSettings.defaultAppSpacing)
        #expect(factory.fontSize == SidebarSettings.defaultFontSize)
        #expect(factory.shadowOpacity == SidebarSettings.defaultShadowOpacity)
        #expect(factory.snapDistance == SidebarSettings.defaultSnapDistance)
        SidebarSettings.save(factory, for: "A", name: "Renamed display", in: restarted)
        #expect(SidebarSettings.configuration(for: "A", in: restarted) == factory)
        #expect(SidebarSettings.configuration(for: "B", in: restarted) == original)
        #expect(SidebarSettings.configuration(for: nil, in: restarted) == original)
    }

    @Test func sidebarTargetsRespectOffDisconnectReconnectAndModeSwitches() throws {
        let suite = "SidebarTargets-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B"], in: defaults) == [.single])
        #expect(SidebarSettings.targets(connectedDisplayIDs: [], in: defaults).isEmpty)
        defaults.set(true, forKey: SidebarSettings.multiDisplayKey)
        SidebarSettings.rememberDisplay(id: "A", name: "A", in: defaults)
        SidebarSettings.rememberDisplay(id: "B", name: "B", in: defaults)
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B", "A"], in: defaults)
            == [.display("A"), .display("B")])
        var off = SidebarSettings.configuration(for: "B", in: defaults)
        off.enabled = false
        SidebarSettings.save(off, for: "B", name: "B", in: defaults)
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B"], in: defaults) == [.display("A")])
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["B"], in: defaults).isEmpty)
        // Reordering displays does not alter their preferences or re-enable an Off display.
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["B", "A"], in: defaults) == [.display("A")])
        defaults.set(false, forKey: "sidebarEnabled")
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B"], in: defaults).isEmpty)
        SidebarSettings.rememberDisplay(id: "C", name: "C", in: defaults)
        #expect(SidebarSettings.configuration(for: "C", in: defaults).enabled)
        defaults.set(true, forKey: "sidebarEnabled")
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B"], in: defaults) == [.display("A")])
        defaults.set(false, forKey: SidebarSettings.multiDisplayKey)
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B"], in: defaults) == [.single])
        defaults.set(true, forKey: SidebarSettings.multiDisplayKey)
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B"], in: defaults) == [.display("A")])
    }

    @Test func damagedDisplayPreferencesDoNotLoseOtherDisplaysAndValuesAreBounded() throws {
        let suite = "SidebarDisplayRecovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var configuration = SidebarConfiguration(defaults: defaults)
        configuration.position = .nan
        configuration.appSpacing = -10
        configuration.fontSize = 100
        configuration.shadowOpacity = .infinity
        configuration.snapDistance = 900
        SidebarSettings.save(configuration, for: "A", name: "A", in: defaults)
        var saved = defaults.dictionary(forKey: SidebarSettings.displayPreferencesKey) ?? [:]
        saved["broken"] = Data("invalid".utf8)
        defaults.set(saved, forKey: SidebarSettings.displayPreferencesKey)
        let loaded = SidebarSettings.configuration(for: "A", in: defaults)
        #expect(loaded.position == 0.5)
        #expect(loaded.appSpacing == 0)
        #expect(loaded.fontSize == SidebarSettings.maximumFontSize)
        #expect(loaded.shadowOpacity == SidebarSettings.defaultShadowOpacity)
        #expect(loaded.snapDistance == SidebarSettings.maximumSnapDistance)
        SidebarSettings.rememberDisplay(id: "broken", name: "Recovered", in: defaults)
        #expect(SidebarSettings.configuration(for: "A", in: defaults) == loaded)
        #expect(SidebarSettings.displayPreferences(in: defaults)["broken"]?.name == "Recovered")
    }

    @MainActor @Test func appVisibilityButtonHidesOrShowsTheSelectedWindowOfAMultiWindowApp() {
        let app = Application(NSRunningApplication.current)
        let first = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: "First")
        first.cgWindowID = 10
        let second = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: "Second")
        second.cgWindowID = 20
        let state = CyclePanelState()
        let target = SidebarWindowID(pid: getpid(), windowID: 20)
        let normal = SidebarWindowState(isMinimized: false, canMinimize: true)
        let states = [CGWindowID(10): normal, CGWindowID(20): normal]
        state.setWindows([first, second], applicationTitle: "Example", selectedID: 20,
                         sidebarWindowStates: states, sidebarAppIsHidden: true)
        #expect(state.sidebarAppVisibilityTitle == "Show app")
        let show = state.sidebarAppVisibilityAction(pid: getpid())
        #expect(show == .focus(target))
        state.reset()
        #expect(show == .focus(target))
        #expect(state.sidebarAppVisibilityAction(pid: getpid()) == nil)
        state.setWindows([first, second], applicationTitle: "Example", selectedID: 20,
                         sidebarWindowStates: states, sidebarAppIsHidden: false)
        #expect(state.sidebarAppVisibilityTitle == "Hide app")
        #expect(state.sidebarAppVisibilityAction(pid: getpid()) == .hide(target))
    }

    @Test func browserMenusKeepTheSameRealWindowsWhenOpenAndMinimised() {
        let frame = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let realTitles = ["New Tab - Brave - Personal", "Google - Brave - ü"]
        for minimized in [false, true] {
            for title in realTitles {
                #expect(!SidebarWindowPolicy.isBrowserHelper(title: title, applicationTitle: "Brave Browser",
                    subrole: kAXStandardWindowSubrole as String, hasCloseButton: true, parentIsWindow: false,
                    bounds: frame, minimized: minimized))
            }
        }
        // During minimise/restore, controls or CG geometry can briefly disappear.
        #expect(!SidebarWindowPolicy.isBrowserHelper(title: realTitles[0], applicationTitle: "Brave Browser",
            subrole: kAXStandardWindowSubrole as String, hasCloseButton: false, parentIsWindow: false,
            bounds: CGRect(x: 0, y: 30, width: 1, height: 1), minimized: true))
        #expect(!SidebarWindowPolicy.isBrowserHelper(title: realTitles[0], applicationTitle: "Brave Browser",
            subrole: kAXStandardWindowSubrole as String, hasCloseButton: false, parentIsWindow: false,
            bounds: CGRect(x: 0, y: 30, width: 1, height: 1), minimized: false))
        for title in ["Brave Browser", ""] {
            #expect(SidebarWindowPolicy.isBrowserHelper(title: title, applicationTitle: "Brave Browser",
                subrole: kAXStandardWindowSubrole as String, hasCloseButton: false, parentIsWindow: false,
                bounds: frame, minimized: false))
            // An untitled real browser window must not be removed by its name.
            #expect(!SidebarWindowPolicy.isBrowserHelper(title: title, applicationTitle: "Brave Browser",
                subrole: kAXStandardWindowSubrole as String, hasCloseButton: true, parentIsWindow: false,
                bounds: frame, minimized: false))
        }
        #expect(SidebarWindowPolicy.isBrowserHelper(title: "Restore pages?", applicationTitle: "Brave Browser",
            subrole: "AXUnknown", hasCloseButton: false, parentIsWindow: true, bounds: frame, minimized: false))
        #expect(SidebarWindowPolicy.isBrowserHelper(title: nil, applicationTitle: "Google Chrome",
            subrole: kAXStandardWindowSubrole as String, hasCloseButton: false, parentIsWindow: false,
            bounds: CGRect(x: 0, y: 30, width: 1, height: 1), minimized: false))
        // A temporary AX failure is not proof that a normal window has no controls.
        #expect(!SidebarWindowPolicy.isBrowserHelper(title: nil, applicationTitle: "Brave Browser",
            subrole: nil, hasCloseButton: nil, parentIsWindow: false, bounds: frame, minimized: false))
        #expect(!SidebarWindowPolicy.needsBrowserHelperCheck(bundleIdentifier: "com.apple.finder"))
    }

    @Test func remoteDiscoveryRejectsBrowserTabsAndRestoreSurfaces() {
        #expect(SidebarWindowDiscovery.isEligibleRemoteWindow(
            role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String
        ))
        for subrole in [nil, "", "AXUnknown", kAXDialogSubrole as String] as [String?] {
            #expect(!SidebarWindowDiscovery.isEligibleRemoteWindow(
                role: kAXWindowRole as String, subrole: subrole
            ))
        }
        #expect(!SidebarWindowDiscovery.isEligibleRemoteWindow(
            role: kAXButtonRole as String, subrole: kAXStandardWindowSubrole as String
        ))
    }

    @Test func spaceNumbersFollowOrderWithoutCountingFullScreenOrDuplicateSpaces() {
        let spaces: [[String: Any]] = [["Spaces": [
            ["id64": 10, "type": 0], ["ManagedSpaceID": 11, "type": 4],
            ["id64": 12, "type": 0], ["id64": 99, "type": 2]
        ]], ["Spaces": [["id64": 10, "type": 0], ["id64": 13, "type": 0]]]]
        let result = SidebarSpaceReader.desktops(from: spaces)
        #expect(result.map(\.id) == [10, 11, 12, 13])
        #expect(result.map(\.number) == [1, nil, 2, 3])
        #expect(result[2].windowPrefix == "2. ")
    }

    @Test func legacyAutoHideMigratesToIdleBehaviorWithoutOverridingANewChoice() throws {
        let suite = "SidebarIdleMigration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "sidebarAutoHide")
        SidebarSettings.migrateLegacyAutoHide(in: defaults)
        #expect(defaults.string(forKey: SidebarSettings.idleBehaviorKey) == "hide")
        #expect(defaults.object(forKey: "sidebarAutoHide") == nil)

        defaults.set(false, forKey: "sidebarAutoHide")
        SidebarSettings.migrateLegacyAutoHide(in: defaults)
        #expect(defaults.string(forKey: SidebarSettings.idleBehaviorKey) == "hide")

        defaults.removeObject(forKey: SidebarSettings.idleBehaviorKey)
        defaults.set(false, forKey: "sidebarAutoHide")
        SidebarSettings.migrateLegacyAutoHide(in: defaults)
        #expect(defaults.string(forKey: SidebarSettings.idleBehaviorKey) == "stayVisible")

        #expect(SidebarIdleBehavior.saved(nil) == .fade)
        #expect(SidebarIdleBehavior.saved("bogus") == .fade)
    }

    @Test func windowOnEveryDesktopOfADisplayCollapsesToTheVisibleDesktop() {
        let a1 = SidebarDesktop(id: 5, order: 0, number: 1, displayIdentifier: "a")
        let a2 = SidebarDesktop(id: 6, order: 1, number: 2, displayIdentifier: "a")
        let a3 = SidebarDesktop(id: 7, order: 2, number: 3, displayIdentifier: "a")
        let b1 = SidebarDesktop(id: 8, order: 3, number: 4, displayIdentifier: "b")
        let b2 = SidebarDesktop(id: 9, order: 4, number: 5, displayIdentifier: "b")
        let catalog = [a1, a2, a3, b1, b2]
        func collapse(_ membership: [SidebarDesktop], visible: Set<UInt64>) -> [SidebarDesktop] {
            SidebarSpaceReader.collapsingAllDesktopsMembership(membership, catalog: catalog, visible: visible)
        }
        // Sticky on display b only: one row, on b's visible desktop.
        #expect(collapse([b1, b2], visible: [5, 9]) == [b2])
        // No visible desktop known: deterministic fallback to the first.
        #expect(collapse([b1, b2], visible: []) == [b1])
        // Sticky on both displays: one row per display.
        #expect(collapse([a1, a2, a3, b1, b2], visible: [6, 8]) == [a2, b1])
        // Partial membership and single-desktop windows are real placements.
        #expect(collapse([a1, a2], visible: [5]) == [a1, a2])
        #expect(collapse([a1], visible: [5]) == [a1])
        #expect(collapse([], visible: []).isEmpty)
    }

    @MainActor @Test func repeatedAppIconsHaveDistinctIdentitiesAndOnlyTheirDesktopsWindows() throws {
        let running = NSRunningApplication.current
        let pid = running.processIdentifier
        let app = Application(running)
        let desktop1 = SidebarDesktop(id: 100, order: 0, number: 1)
        let desktop2 = SidebarDesktop(id: 200, order: 1, number: 2)
        func window(_ id: CGWindowID) -> Window {
            let window = Window(AXUIElementCreateApplication(pid), app, cachedTitle: "Window \(id)")
            window.cgWindowID = id
            return window
        }
        let remote = SidebarWindowID(pid: pid, windowID: 30)
        let entry = SidebarEntry(pid: pid, application: app, windows: [window(10), window(20), window(30)],
            preferredID: remote, focusedID: remote, windowStates: [
                10: SidebarWindowState(isMinimized: false, canMinimize: true, isOnScreen: true, desktops: [desktop1]),
                20: SidebarWindowState(isMinimized: true, canMinimize: true, isOnScreen: false, desktops: [desktop1]),
                30: SidebarWindowState(isMinimized: false, canMinimize: true, isOnScreen: false, desktops: [desktop2])
            ])
        let groups = SidebarWindowInventory.entries(for: [running], windowEntries: [entry], scope: .allDesktops)
        #expect(groups.count == 2)
        let first = try #require(groups.first)
        let second = try #require(groups.last)
        #expect(first.id != second.id)
        #expect(first.pid == second.pid)
        #expect(first.windows.map(\.cgWindowID) == [10, 20])
        #expect(second.windows.map(\.cgWindowID) == [30])
        #expect(second.hasOtherWindows) // A multi-window app still gets a menu for its one-window group.
        #expect(first.windowStates[10]?.desktopLabel == "1. ")
        #expect(second.windowStates[30]?.desktopLabel == "2. ")
        #expect(second.focusedID == remote)
        #expect(first.focusedID == nil)
        for setting in SidebarActiveAppClickAction.allCases {
            #expect(SidebarIconClickPolicy.action(for: second, frontmostPID: pid, setting: setting) == .focus(remote))
        }
        #expect(SidebarWindowInventory.separatorIndices(entries: groups, scope: .allDesktops) == [1])
        #expect(SidebarWindowInventory.separatorIndices(entries: groups, scope: .visibleDesktops).isEmpty)
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let plain = SidebarLayout.sidebarFrame(in: frame, count: 2, side: .right, position: 0.5, appSpacing: 4)
        let separated = SidebarLayout.sidebarFrame(in: frame, count: 2, side: .right, position: 0.5,
                                                   appSpacing: 4, separatorCount: 1)
        #expect(separated.height - plain.height == SidebarLayout.desktopSeparatorHeight + 4)
    }

    @Test func desktopScopeDefaultsToAllDesktops() {
        #expect(SidebarDesktopScope.saved(nil) == .allDesktops)
        #expect(SidebarDesktopScope.saved("invalid") == .allDesktops)
        for scope in SidebarDesktopScope.allCases {
            #expect(SidebarDesktopScope.saved(scope.rawValue) == scope)
        }
    }

    @MainActor @Test func allDesktopsKeepsRunningAppsWhenMacOSReturnsNoWindows() throws {
        let running = NSRunningApplication.current
        // Feed the production inventory assembler a real running app and an empty AX result.
        let entries = SidebarWindowInventory.entries(for: [running], windowEntries: [], scope: .allDesktops)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.pid == running.processIdentifier)
        #expect(entry.windows.isEmpty)
        #expect(entry.preferredID == nil)
        #expect(entry.preferredWindow == nil)
        for setting in SidebarActiveAppClickAction.allCases {
            for frontmost in [nil, Optional(running.processIdentifier)] {
                let action = SidebarIconClickPolicy.action(for: entry, frontmostPID: frontmost, setting: setting)
                #expect(action == .activateApp(running.processIdentifier))
                #expect(action?.target == nil)
            }
        }
        #expect(SidebarWindowInventory.entries(for: [running], windowEntries: [], scope: .visibleDesktops).isEmpty)
    }

    @MainActor @Test func allDesktopsMergesWindowListsWithoutDuplicatingApps() throws {
        let running = NSRunningApplication.current
        let app = Application(running)
        let id = SidebarWindowID(pid: running.processIdentifier, windowID: 10)
        let window = Window(AXUIElementCreateApplication(id.pid), app, cachedTitle: "Readable window")
        window.cgWindowID = id.windowID
        let original = SidebarEntry(pid: id.pid, application: app, windows: [window], preferredID: id)
        let entries = SidebarWindowInventory.entries(for: [running], windowEntries: [original], scope: .allDesktops)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.preferredID == id)
        #expect(entry.windows.map(\.cgWindowID) == [10])
        #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: nil, setting: .minimize) == .focus(id))
    }

    @MainActor @Test func finderNeedsAWindowButMinimisedWindowsKeepItListed() throws {
        let running = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        #expect(SidebarWindowInventory.entries(for: [running], windowEntries: [], scope: .allDesktops).isEmpty)
        let app = Application(running)
        let id = SidebarWindowID(pid: running.processIdentifier, windowID: 10)
        let window = Window(AXUIElementCreateApplication(id.pid), app, cachedTitle: "Downloads")
        window.cgWindowID = id.windowID
        let entry = SidebarEntry(pid: id.pid, application: app, windows: [window], preferredID: id,
            windowStates: [10: SidebarWindowState(isMinimized: true, canMinimize: true, isOnScreen: false)])
        for scope in SidebarDesktopScope.allCases {
            let entries = SidebarWindowInventory.entries(for: [running], windowEntries: [entry], scope: scope)
            #expect(entries.count == 1)
            #expect(entries.first?.windows.map(\.cgWindowID) == [10])
        }
    }

    @Test func activeAppClickDefaultsAndInvalidValuesUseMinimise() {
        #expect(SidebarActiveAppClickAction.saved(nil) == .minimize)
        #expect(SidebarActiveAppClickAction.saved("invalid") == .minimize)
        for value in SidebarActiveAppClickAction.allCases {
            #expect(SidebarActiveAppClickAction.saved(value.rawValue) == value)
        }
    }

    @MainActor @Test func iconClicksRespectFocusAndRestoreBeforeToggling() {
        let app = Application(NSRunningApplication.current)
        let pid = getpid()
        let first = SidebarWindowID(pid: pid, windowID: 10)
        let second = SidebarWindowID(pid: pid, windowID: 20)
        func window(_ id: CGWindowID) -> Window {
            let window = Window(AXUIElementCreateApplication(pid), app, cachedTitle: "Window")
            window.cgWindowID = id
            return window
        }
        var entry = SidebarEntry(pid: pid, application: app, windows: [window(10), window(20)], preferredID: first,
                                 focusedID: second)
        for setting in SidebarActiveAppClickAction.allCases {
            #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: nil, setting: setting) == .focus(first))
        }
        #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: .none) == .focus(first))
        #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: .hide) == .hide(first))
        // Minimise the focused window, even when a different cached window is preferred.
        #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: .minimize)
                == .minimize(second, requireFocused: true))
        entry.focusedID = nil // A modal/nonstandard window must not minimise a substitute.
        #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: .minimize) == nil)
        entry.windowStates = [10: SidebarWindowState(isMinimized: true, canMinimize: true),
                              20: SidebarWindowState(isMinimized: true, canMinimize: true)]
        for setting in SidebarActiveAppClickAction.allCases {
            #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: setting) == .focus(first))
        }
        entry.windowStates = [:]
        entry.isHidden = true
        #expect(entry.visibleIDs.isEmpty)
        #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: .hide) == .focus(first))
    }

    @Test func minimiseRejectsUnsupportedFullScreenAndModalWindows() {
        #expect(SidebarWindowPolicy.canMinimize(standardWindow: true, fullScreen: false, modal: false,
                                              hasSheets: false, settable: true))
        for state in [(false, false, false, false, true), (true, true, false, false, true),
                      (true, false, true, false, true), (true, false, false, true, true),
                      (true, false, false, false, false)] {
            #expect(!SidebarWindowPolicy.canMinimize(standardWindow: state.0, fullScreen: state.1,
                modal: state.2, hasSheets: state.3, settable: state.4))
        }
    }

    @Test func queuedActionsCanBeCancelledRepeatedly() {
        let action = SidebarPendingAction(frontmostPID: nil)
        #expect(!action.isCancelled)
        #expect(!action.hasStartedFocus)
        #expect(action.beginFocus())
        #expect(action.hasStartedFocus)
        action.cancel()
        action.cancel()
        #expect(action.isCancelled)
        #expect(!action.isCurrent)
        #expect(!action.beginFocus())
    }

    @MainActor @Test func anActiveAppOnAnotherDesktopIsFocusedInsteadOfHiddenOrMinimised() {
        let pid = getpid()
        let app = Application(NSRunningApplication.current)
        let id = SidebarWindowID(pid: pid, windowID: 10)
        let window = Window(AXUIElementCreateApplication(pid), app, cachedTitle: "Other desktop")
        window.cgWindowID = id.windowID
        let entry = SidebarEntry(pid: pid, application: app, windows: [window], preferredID: id, focusedID: id,
            windowStates: [10: SidebarWindowState(isMinimized: false, canMinimize: false, isOnScreen: false)])
        #expect(entry.visibleIDs.isEmpty)
        for setting in SidebarActiveAppClickAction.allCases {
            #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: setting) == .focus(id))
        }
    }

    @MainActor @Test func rapidRepeatsAreBlockedButLaterGroupedClicksAreAccepted() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 86, height: 86))
        var clicks = 0
        view.onClick = { clicks += 1 }
        // Grouped clicks less than 230 ms after the last accepted click are suppressed.
        // Use 240 ms for accepted repeats to stay clear of the floating-point boundary.
        let events: [(TimeInterval, Int, Int)] = [(1, 1, 1), (1.05, 2, 1), (1.1, 3, 1),
                                                (1.24, 4, 2), (1.3, 5, 2), (1.48, 6, 3),
                                                (1.49, 1, 4)]
        for (timestamp, count, expectedClicks) in events {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                modifierFlags: [], timestamp: timestamp, windowNumber: 0, context: nil,
                eventNumber: count, clickCount: count, pressure: 1))
            view.mouseDown(with: event)
            let release = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
                modifierFlags: [], timestamp: timestamp + 0.01, windowNumber: 0, context: nil,
                eventNumber: count, clickCount: count, pressure: 0))
            view.mouseUp(with: release)
            #expect(clicks == expectedClicks)
        }
    }

    @MainActor @Test func menuStateRefreshesWindowControlsAndClearsThemForKeyboardMode() {
        let app = Application(NSRunningApplication.current)
        let window = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: "Example")
        window.cgWindowID = 10
        let state = CyclePanelState()
        let normal = SidebarWindowState(isMinimized: false, canMinimize: true)
        let minimized = SidebarWindowState(isMinimized: true, canMinimize: true)
        state.setWindows([window], applicationTitle: "Example", selectedID: 10, sidebarWindowStates: [10: normal])
        #expect(state.showsSidebarActions)
        state.selectFromPointer(0)
        state.setWindows([window], applicationTitle: "Example", selectedID: 10,
                         preserveInteraction: true, sidebarWindowStates: [10: minimized])
        #expect(state.sidebarWindowStates[10] == minimized)
        #expect(!state.shouldScrollToSelection)
        #expect(state.currentWindow?.cgWindowID == 10)
        state.setWindows([window], applicationTitle: "Example", selectedID: 10,
                         preserveInteraction: true, sidebarWindowStates: [10: normal], sidebarAppIsHidden: true)
        #expect(state.sidebarAppIsHidden)
        #expect(!state.sidebarWindowStates[10]!.isMinimized)
        state.setApplication(app)
        #expect(!state.showsSidebarActions)
        #expect(state.sidebarWindowStates.isEmpty)
        #expect(state.showsHeader)
        #expect(!state.sidebarAppIsHidden)
        state.reset()
        #expect(!state.showsSidebarActions)
    }

    @Test func ordinaryVisibleHiddenAndMinimisedWindowsAreEligible() {
        #expect(SidebarWindowPolicy.isEligible(onScreen: true, normalLevel: true, standardWindow: true,
                                              minimized: false, hidden: false, ownProcess: false))
        // Startup discovery must also include windows that were never on screen this session.
        for state in [(false, true, false), (false, false, true), (false, true, true)] {
            #expect(SidebarWindowPolicy.isEligible(onScreen: state.0, normalLevel: true,
                standardWindow: true, minimized: state.1, hidden: state.2, ownProcess: false))
        }
        // Inactive-desktop visible windows and nonstandard/own-process windows stay excluded.
        let excluded = [
            (false, true, true, false, false, false), // inactive desktop
            (true, false, true, false, false, false), // utility panel
            (true, true, false, false, false, false), // non-standard window
            (true, true, true, false, false, true)    // octopus itself
        ]
        for value in excluded {
            #expect(!SidebarWindowPolicy.isEligible(onScreen: value.0, normalLevel: value.1,
                                                   standardWindow: value.2, minimized: value.3,
                                                   hidden: value.4, ownProcess: value.5))
        }
    }

    @Test func dockTransitionsKeepAnExistingAppInTheSameSidebarSlot() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let original = SidebarLayout.sidebarFrame(in: screen, count: 3, side: .right, position: 0.5)
        // CG can report off-screen before AX reports minimised, and during restore the
        // reverse happens. The AX window still exists throughout these snapshots.
        for (onScreen, minimized) in [(true, false), (false, false), (false, true),
                                      (false, false), (true, false)] {
            let staysListed = SidebarWindowPolicy.isEligible(onScreen: onScreen, normalLevel: true,
                standardWindow: true, minimized: minimized, hidden: false, ownProcess: false,
                previouslyListed: true)
            #expect(staysListed)
            let frame = SidebarLayout.sidebarFrame(in: screen, count: staysListed ? 3 : 2,
                                                   side: .right, position: 0.5)
            #expect(frame == original)
        }
        // Clearing desktop history must not admit an ordinary window on another desktop.
        #expect(!SidebarWindowPolicy.isEligible(onScreen: false, normalLevel: true, standardWindow: true,
            minimized: false, hidden: false, ownProcess: false, previouslyListed: false))
        #expect(!SidebarWindowPolicy.isEligible(onScreen: false, normalLevel: true, standardWindow: false,
            minimized: false, hidden: false, ownProcess: false, previouslyListed: true))
    }

    @Test func allDesktopsIncludesOffScreenWindowsButStillExcludesPanelsAndoctopus() {
        #expect(SidebarWindowPolicy.isEligible(onScreen: false, normalLevel: true, standardWindow: true,
            minimized: false, hidden: false, ownProcess: false, scope: .allDesktops))
        #expect(!SidebarWindowPolicy.isEligible(onScreen: false, normalLevel: true, standardWindow: true,
            minimized: false, hidden: false, ownProcess: false, scope: .visibleDesktops))
        for value in [(false, true, false), (true, false, false), (true, true, true)] {
            #expect(!SidebarWindowPolicy.isEligible(onScreen: false, normalLevel: value.0,
                standardWindow: value.1, minimized: false, hidden: false,
                ownProcess: value.2, scope: .allDesktops))
        }
    }

    @Test func popupOwnsInputWhereItOverlapsTheSidebar() {
        let sidebar = CGRect(x: 1000, y: 200, width: SidebarLayout.width, height: 300)
        let screen = CGRect(x: 0, y: 0, width: 1100, height: 900)
        let iconSize = SidebarLayout.iconSize * (1 + SidebarLayout.magnificationGrowth)
        let icon = CGRect(x: sidebar.midX - iconSize / 2, y: sidebar.midY - iconSize / 2,
                          width: iconSize, height: iconSize)
        let menu = SidebarLayout.menuFrame(size: CGSize(width: 280, height: 120), icon: icon,
                                           screen: screen, side: .right)
        let overlap = sidebar.intersection(menu)
        #expect(!overlap.isEmpty)
        let point = CGPoint(x: overlap.midX, y: overlap.midY)
        #expect(!SidebarLayout.acceptsSidebarPointer(at: point, sidebar: sidebar, menu: menu))
        #expect(SidebarLayout.acceptsSidebarPointer(at: point, sidebar: sidebar, menu: nil))
        #expect(SidebarLayout.acceptsSidebarPointer(at: CGPoint(x: sidebar.maxX - 5, y: sidebar.midY),
                                                    sidebar: sidebar, menu: menu))
        #expect(!SidebarLayout.acceptsSidebarPointer(at: .zero, sidebar: sidebar, menu: menu))
    }

    @Test func topLevelWindowsAreAcceptedWhenSubroleIsMissing() {
        #expect(SidebarWindowPolicy.isTopLevelWindow(role: kAXWindowRole as String, subrole: nil))
        #expect(SidebarWindowPolicy.isTopLevelWindow(role: kAXWindowRole as String, subrole: "AXUnknown"))
        #expect(SidebarWindowPolicy.isTopLevelWindow(
            role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String
        ))
        #expect(!SidebarWindowPolicy.isTopLevelWindow(role: kAXButtonRole as String, subrole: nil))
        #expect(!SidebarWindowPolicy.isTopLevelWindow(role: kAXWindowRole as String, subrole: "AXCloseButton"))
    }

    @Test func windowTitlesAreMatchedWithoutCaseOrOuterWhitespace() {
        #expect(SidebarWindowPolicy.normalizedWindowTitle("  New Tab - Google Chrome  ") == "new tab - google chrome")
        #expect(SidebarWindowPolicy.normalizedWindowTitle("Safari") != "safari window")
    }

    @Test func selectionUsesEligibleHistoryThenFocusThenFirstWindow() {
        let first = SidebarWindowID(pid: 1, windowID: 10)
        let second = SidebarWindowID(pid: 1, windowID: 20)
        let stale = SidebarWindowID(pid: 2, windowID: 10)
        #expect(first != stale)
        #expect(SidebarWindowPolicy.preferredID([first, second], recency: [first: 1, second: 2, stale: 3], focused: first) == second)
        #expect(SidebarWindowPolicy.preferredID([first, second], recency: [stale: 3], focused: second) == second)
        #expect(SidebarWindowPolicy.preferredID([first], recency: [:], focused: second) == first)
        #expect(SidebarWindowPolicy.preferredID([], recency: [first: 1], focused: first) == nil)

        let states: [CGWindowID: SidebarWindowState] = [
            10: SidebarWindowState(isMinimized: false, canMinimize: true, isOnScreen: true),
            20: SidebarWindowState(isMinimized: false, canMinimize: false, isOnScreen: false)
        ]
        // A newer off-desktop window must not take an icon click away from a visible one.
        #expect(SidebarWindowPolicy.preferredID([first, second], recency: [first: 1, second: 2],
            focused: second, states: states) == first)
        #expect(SidebarWindowPolicy.preferredID([second], recency: [:],
            focused: second, states: states) == second)
        #expect(SidebarWindowPolicy.preferredID([first, second], recency: [first: 1, second: 2],
            focused: first, states: states, hidden: true) == second)
    }

    @Test func sidebarPositionUsesSelectedScreenAndClampsOverflow() {
        let screen = CGRect(x: -1440, y: 120, width: 1440, height: 850)
        let top = SidebarLayout.sidebarFrame(in: screen, count: 2, side: .right, position: 0)
        let middle = SidebarLayout.sidebarFrame(in: screen, count: 2, side: .right, position: 0.5)
        let bottom = SidebarLayout.sidebarFrame(in: screen, count: 2, side: .left, position: 1)
        #expect(top.maxX == screen.maxX)
        #expect(top.maxY == screen.maxY)
        #expect(middle.midY == screen.midY)
        #expect(bottom.minX == screen.minX)
        #expect(bottom.minY == screen.minY)
        let overflow = SidebarLayout.sidebarFrame(in: screen, count: 100, side: .right, position: 1.5)
        #expect(overflow.height == screen.height)
        #expect(screen.contains(overflow))
    }

    @Test func menuStaysNearIconAndWithinItsMonitor() {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let icon = CGRect(x: -70, y: 200, width: 40, height: 40)
        let right = SidebarLayout.menuFrame(size: CGSize(width: 400, height: 300), icon: icon, screen: screen, side: .right)
        #expect(right.maxX == icon.minX - SidebarLayout.menuGap)
        #expect(right.midY == icon.midY - 18)
        let leftIcon = CGRect(x: screen.minX + 30, y: screen.maxY - 40, width: 40, height: 40)
        let left = SidebarLayout.menuFrame(size: CGSize(width: 400, height: 500), icon: leftIcon, screen: screen, side: .left)
        #expect(left.minX == leftIcon.maxX + SidebarLayout.menuGap)
        #expect(left.maxY == screen.maxY)
        #expect(screen.contains(left))
        let oversized = SidebarLayout.menuFrame(size: CGSize(width: 2000, height: 2000), icon: icon, screen: screen, side: .right)
        #expect(oversized == screen)
        let bottomIcon = CGRect(x: screen.minX + 30, y: screen.minY + 10, width: 40, height: 40)
        let nearBottom = SidebarLayout.menuFrame(size: CGSize(width: 400, height: 300), icon: bottomIcon,
                                                screen: screen, side: .left)
        #expect(nearBottom.minY == screen.minY)
        #expect(screen.contains(nearBottom))
    }

    @Test func releasingModifiersOnlyCommitsKeyboardSessions() {
        let required: NSEvent.ModifierFlags = [.control, .option]
        #expect(!CyclePanelPresentation.sidebar.shouldCommit(required: required, pressed: []))
        #expect(!CyclePanelPresentation.keyboard.shouldCommit(required: required, pressed: required))
        #expect(CyclePanelPresentation.keyboard.shouldCommit(required: required, pressed: [.control]))
        #expect(!CyclePanelPresentation.keyboard.shouldCommit(required: [], pressed: []))
    }

    @MainActor @Test func unchangedRefreshKeepsRowsSelectionAndScrollIntent() {
        let app = Application(NSRunningApplication.current)
        func window(_ id: CGWindowID) -> Window {
            let result = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: "Window \(id)")
            result.cgWindowID = id
            return result
        }
        let state = CyclePanelState()
        state.setWindows([window(10), window(20)], applicationTitle: "Example", selectedID: 20)
        state.selectFromPointer(1)
        var rowUpdates = 0
        let subscription = state.$items.dropFirst().sink { _ in rowUpdates += 1 }
        defer { subscription.cancel() }

        state.setWindows([window(20), window(10)], applicationTitle: "Example", selectedID: 20,
                         preserveInteraction: true)
        #expect(rowUpdates == 0)
        #expect(state.windows.map(\.cgWindowID) == [10, 20])
        #expect(state.currentWindow?.cgWindowID == 20)
        #expect(!state.shouldScrollToSelection)
    }

    @MainActor @Test func changedRefreshUpdatesTitlesAppendsWindowsAndHandlesClosedSelection() {
        let app = Application(NSRunningApplication.current)
        func window(_ id: CGWindowID, title: String = "Window") -> Window {
            let result = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: title)
            result.cgWindowID = id
            return result
        }
        let state = CyclePanelState()
        state.setWindows([window(10), window(20)], applicationTitle: "Example", selectedID: 20)
        let selectedRowID = state.currentItem?.id
        state.setWindows([window(30), window(20, title: "Renamed"), window(10), window(20)],
                         applicationTitle: "Example", selectedID: 20, preserveInteraction: true)
        #expect(state.windows.map(\.cgWindowID) == [10, 20, 30])
        #expect(state.currentItem?.id == selectedRowID)
        #expect(state.currentWindow?.title == "Renamed")
        #expect(!state.shouldScrollToSelection)
        state.cycleNext()
        #expect(state.currentWindow?.cgWindowID == 30)
        #expect(state.shouldScrollToSelection)

        state.setWindows([window(10), window(20)], applicationTitle: "Example", selectedID: 30,
                         preserveInteraction: true)
        #expect(state.currentWindow?.cgWindowID == 20)
        #expect(!state.items.contains { $0.id == .window(30) })
        #expect(!state.shouldScrollToSelection)
        state.setWindows([], applicationTitle: "Example", selectedID: 20, preserveInteraction: true)
        #expect(state.currentItem == nil)
    }

    @MainActor @Test func nativeMenuGeometryDrivesRowAndButtonHoverWithoutCompetingCallbacks() async throws {
        let app = Application(NSRunningApplication.current)
        func window(_ id: CGWindowID, title: String = "Window") -> Window {
            let result = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: title)
            result.cgWindowID = id
            return result
        }
        let state = CyclePanelState()
        let normal = SidebarWindowState(isMinimized: false, canMinimize: true)
        let minimized = SidebarWindowState(isMinimized: true, canMinimize: true)
        state.setWindows([window(10), window(20)], applicationTitle: "Example", selectedID: 10,
                         sidebarWindowStates: [10: normal, 20: minimized])
        var anchors: [CyclePanelItem.ID: NSView] = [:]
        var hideAnchor: NSView?
        let size = CGSize(width: 280, height: SidebarLayout.menuRowHeight * 2 + 1
                          + SidebarLayout.menuPadding * 2 + SidebarLayout.menuActionHeight + 1)
        // A hidden panel exercises real AppKit/SwiftUI layout without touching another app.
        let panel = CyclePanel(contentRect: CGRect(origin: .zero, size: size))
        #expect(panel.animationBehavior == .none)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let hosting = NSHostingView(rootView: CyclePanelView(state: state,
            onAnchor: { anchors[$0] = $1 }, onHideAnchor: { hideAnchor = $0 }))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = try #require(panel.contentView)
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        container.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        container.layoutSubtreeIfNeeded()
        let first = try #require(anchors[.window(10)])
        let second = try #require(anchors[.window(20)])
        #expect(first.bounds.width == size.width - SidebarLayout.menuPadding * 2)
        #expect(first.bounds.height == SidebarLayout.menuRowHeight)
        #expect(second.bounds.height == SidebarLayout.menuRowHeight)
        #expect(!first.visibleRect.isEmpty)
        #expect(!second.visibleRect.isEmpty)
        let initialSize = panel.frame.size
        for index in 0..<12 {
            let row = index % 2 == 0 ? first : second
            // Alternate between the title and action-button region without waiting for a scan.
            let x = index % 3 == 0 ? row.bounds.maxX - 15 : row.bounds.midX
            let point = panel.convertPoint(toScreen: row.convert(CGPoint(x: x, y: row.bounds.midY), to: nil))
            let target = CyclePanelController.sidebarPointerTarget(at: point, items: state.items,
                anchors: anchors, hideAnchor: hideAnchor)
            let id = CyclePanelItem.ID.window(index % 2 == 0 ? 10 : 20)
            #expect(target == (index % 3 == 0 ? .windowAction(id) : .row(id)))
            state.setSidebarPointerTarget(target)
            #expect(state.currentWindow?.cgWindowID == (index % 2 == 0 ? 10 : 20))
            #expect(state.sidebarPointerTarget == target)
            try await Task.sleep(for: .milliseconds(10))
            container.layoutSubtreeIfNeeded()
            #expect(anchors[.window(10)] === first)
            #expect(anchors[.window(20)] === second)
            #expect(first.bounds.height == SidebarLayout.menuRowHeight)
            #expect(second.bounds.height == SidebarLayout.menuRowHeight)
            #expect(panel.frame.size == initialSize)
        }
        // Replayed row events cannot compete with the panel's current pointer position.
        let oldPoint = first.convert(CGPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
        let staleEntry = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: oldPoint,
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        first.mouseEntered(with: staleEntry)
        let staleMove = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: oldPoint,
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        first.mouseMoved(with: staleMove)
        #expect(state.currentWindow?.cgWindowID == 20)
        #expect(state.sidebarPointerTarget == .row(.window(20)))
        let footer = try #require(hideAnchor)
        let footerPoint = panel.convertPoint(toScreen: footer.convert(
            CGPoint(x: footer.bounds.midX, y: footer.bounds.midY), to: nil))
        let footerTarget = CyclePanelController.sidebarPointerTarget(at: footerPoint, items: state.items,
            anchors: anchors, hideAnchor: hideAnchor)
        #expect(footerTarget == .hideApp)
        state.setSidebarPointerTarget(footerTarget)
        #expect(state.sidebarPointerTarget == .hideApp)
        #expect(state.currentWindow?.cgWindowID == 20)
        let outsideTarget = CyclePanelController.sidebarPointerTarget(
            at: CGPoint(x: panel.frame.minX - 10, y: panel.frame.minY - 10), items: state.items,
            anchors: anchors, hideAnchor: hideAnchor)
        #expect(outsideTarget == nil)
        state.setSidebarPointerTarget(outsideTarget)
        #expect(state.sidebarPointerTarget == nil)
        state.setWindows([window(10, title: String(repeating: "Long title ", count: 20)), window(20)],
                         applicationTitle: "Example", selectedID: 20, preserveInteraction: true,
                         sidebarWindowStates: [10: minimized, 20: normal], sidebarAppIsHidden: true)
        try await Task.sleep(for: .milliseconds(50))
        container.layoutSubtreeIfNeeded()
        #expect(panel.frame.size == initialSize)
        #expect(anchors[.window(10)] === first)
        #expect(anchors[.window(20)] === second)
        #expect(first.bounds.height == SidebarLayout.menuRowHeight)
        #expect(second.bounds.height == SidebarLayout.menuRowHeight)
    }

    @MainActor @Test func refreshedMenuPreservesIdentityAndHandlesRemovedSelection() {
        let app = Application(NSRunningApplication.current)
        // Local, inert AX handles: these tests neither inspect nor focus another application's windows.
        func window(_ id: CGWindowID) -> Window {
            let result = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: "Window \(id)")
            result.cgWindowID = id
            return result
        }
        let state = CyclePanelState()
        state.setWindows([window(10), window(20)], applicationTitle: "Example", selectedID: 20)
        #expect(!state.showsHeader)
        #expect(state.currentWindow?.cgWindowID == 20)
        state.selectFromPointer(0)
        #expect(!state.shouldScrollToSelection)
        state.cycleNext()
        #expect(state.shouldScrollToSelection)
        #expect(state.currentWindow?.cgWindowID == 20)
        state.setWindows([window(20), window(10)], applicationTitle: "Example", selectedID: 20)
        #expect(state.selectedIndex == 0)
        state.cyclePrevious()
        #expect(state.currentWindow?.cgWindowID == 10)
        state.cycleNext()
        #expect(state.currentWindow?.cgWindowID == 20)
        state.setWindows([window(10)], applicationTitle: "Example", selectedID: 20)
        #expect(state.currentWindow?.cgWindowID == 10)
        state.setWindows([], applicationTitle: "Example", selectedID: 10)
        #expect(state.currentItem == nil)
        #expect(!state.showsHeader)
    }
}
