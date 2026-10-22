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

    @Test func missionControlAndHoverPreviewKeepTheMapUntilBothTriggersEnd() {
        var state = MissionControlPresentationState()
        state.set(.hoverPreview, presented: true)
        #expect(state.isVisible)
        state.set(.missionControl, presented: true)
        state.set(.hoverPreview, presented: false)
        #expect(state.isVisible)
        state.set(.missionControl, presented: false)
        #expect(!state.isVisible)
        state.set(.missionControl, presented: true)
        state.set(.hoverPreview, presented: true)
        state.set(.missionControl, presented: false)
        #expect(state.isVisible)
        state.set(.hoverPreview, presented: false)
        #expect(!state.isVisible)
    }

    @Test func suspensionClearsBothMapTriggers() {
        var state = MissionControlPresentationState()
        state.set(.missionControl, presented: true)
        state.set(.hoverPreview, presented: true)
        state.clear()
        #expect(!state.isVisible)
    }

    @Test func optionHoverOpensOnlyWhenEnteringAndCanBeRepeatedAfterLeaving() {
        var commandTrigger = MissionControlHoverTrigger()
        let commandEnter = commandTrigger.update(isInside: true, pointerMoved: true, modifiers: .command,
                                                 pressedButtons: 0, canPresent: true)
        #expect(!commandEnter)

        var trigger = MissionControlHoverTrigger()
        let enter = trigger.update(isInside: true, pointerMoved: true, modifiers: .option,
                                   pressedButtons: 0, canPresent: true)
        #expect(enter)
        let moveInside = trigger.update(isInside: true, pointerMoved: true, modifiers: .option,
                                        pressedButtons: 0, canPresent: true)
        #expect(!moveInside)
        _ = trigger.update(isInside: false, pointerMoved: true, modifiers: .option,
                           pressedButtons: 0, canPresent: true)
        let reenter = trigger.update(isInside: true, pointerMoved: true, modifiers: .option,
                                     pressedButtons: 0, canPresent: true)
        #expect(reenter)
    }

    @Test func pressingConfiguredModifierAfterHoverOpensWithoutMovingAgain() {
        var trigger = MissionControlHoverTrigger()
        _ = trigger.update(isInside: true, pointerMoved: true, modifiers: [],
                           required: .control, pressedButtons: 0, canPresent: true)
        let press = trigger.update(isInside: true, pointerMoved: false, modifiers: .control,
                                   required: .control, pressedButtons: 0, canPresent: true)
        let move = trigger.update(isInside: true, pointerMoved: true, modifiers: .control,
                                  required: .control, pressedButtons: 0, canPresent: true)
        #expect(press && !move)
    }

    @Test func optionPressOverStationarySidebarOpensOncePerPress() {
        var trigger = MissionControlHoverTrigger()
        _ = trigger.update(isInside: true, pointerMoved: true, modifiers: [], pressedButtons: 0, canPresent: true)
        let press = trigger.update(isInside: true, pointerMoved: false, modifiers: .option, pressedButtons: 0, canPresent: true)
        let repeated = trigger.update(isInside: true, pointerMoved: false, modifiers: .option, pressedButtons: 0, canPresent: true)
        let release = trigger.update(isInside: true, pointerMoved: false, modifiers: [], pressedButtons: 0, canPresent: true)
        let nextPress = trigger.update(isInside: true, pointerMoved: false, modifiers: .option, pressedButtons: 0, canPresent: true)
        #expect(press && !repeated && !release && nextPress)
    }

    @Test func cursorPlacementKeepsTheEdgeAndClampsAtScreenBoundaries() {
        let available = CGRect(x: -1800, y: -600, width: 1800, height: 900)
        let size = CGSize(width: 136, height: 250)
        for side in [SidebarSide.left, .right] {
            for cursorY in [CGFloat(-1000), -200, 1000] {
                let frame = MissionControlPlacement.frame(in: available, size: size, side: side,
                                                         position: 0, cursorY: cursorY)
                #expect(available.contains(frame))
                #expect(side == .left ? frame.minX == available.minX : frame.maxX == available.maxX)
                if cursorY == -200 { #expect(frame.midY == cursorY) }
                if cursorY < available.minY { #expect(frame.minY == available.minY) }
                if cursorY > available.maxY { #expect(frame.maxY == available.maxY) }
            }
        }
    }

    @Test func optionHoverDoesNotInterruptDragsOtherModifiersOrBlockedInteractions() {
        let blocked: [(NSEvent.ModifierFlags, Int, Bool)] = [
            ([], 0, true), ([.option, .shift], 0, true), ([.option, .command], 0, true),
            ([.control, .option], 0, true), (.option, 1, true), (.option, 0, false)
        ]
        for (modifiers, buttons, canPresent) in blocked {
            var trigger = MissionControlHoverTrigger()
            let requested = trigger.update(isInside: true, pointerMoved: true, modifiers: modifiers,
                                            pressedButtons: buttons, canPresent: canPresent)
            #expect(!requested)
        }
    }

    @Test func hoverModifiersDefaultToOptionAndPersistCustomOrDisabledChoices() throws {
        let suite = "MissionControlHoverTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MissionControlHoverShortcut.modifiers(in: defaults) == .option)
        let custom: NSEvent.ModifierFlags = [.option, .shift]
        defaults.set(Int(custom.rawValue), forKey: MissionControlHoverShortcut.modifiersKey)
        #expect(MissionControlHoverShortcut.modifiers(in: defaults) == custom)
        var trigger = MissionControlHoverTrigger()
        let opened = trigger.update(isInside: true, pointerMoved: true, modifiers: custom,
            required: MissionControlHoverShortcut.modifiers(in: defaults), pressedButtons: 0, canPresent: true)
        #expect(opened)
        #expect(MissionControlHoverShortcut.isHeld(custom.union(.command), required: custom))
        #expect(!MissionControlHoverShortcut.isHeld(.option, required: custom))
        #expect(!MissionControlHoverShortcut.isHeld(.shift, required: custom))
        defaults.set(0, forKey: MissionControlHoverShortcut.modifiersKey)
        let disabled = MissionControlHoverShortcut.modifiers(in: defaults)
        #expect(disabled.isEmpty && !MissionControlHoverShortcut.matches([], required: disabled))
        #expect(!MissionControlHoverShortcut.isHeld(.option, required: disabled))
        defaults.set("invalid", forKey: MissionControlHoverShortcut.modifiersKey)
        #expect(MissionControlHoverShortcut.modifiers(in: defaults) == .option)
    }

    @Test func placementFollowsSidebarSideAndPositionWithinVisibleScreen() {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: 270, width: 1920, height: 986)
        let available = MissionControlPlacement.availableFrame(screen: screen, visibleFrame: visible)
        let size = CGSize(width: 136, height: 250)
        #expect(available.maxY == visible.maxY - 8)
        #expect(available.minY == visible.minY + 8)
        let shortScreen = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let shortArea = MissionControlPlacement.availableFrame(screen: shortScreen, visibleFrame: shortScreen)
        #expect(shortArea.maxY == shortScreen.maxY - 8)
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
        state.invalidateRequests()
        state.clearCache()
        let late = state.receive(initial, generation: oldGeneration)
        #expect(!late && state.snapshot == nil)
    }

    @Test func snapshotCanBeKeptForImmediatePreviewWhileInvalidatingInFlightReads() {
        var state = MissionControlSnapshotState()
        let cached = snapshot([record()])
        let oldGeneration = state.generation
        let accepted = state.receive(cached, generation: oldGeneration)
        #expect(accepted)
        state.invalidateRequests()
        #expect(state.snapshot?.windows == cached.windows)
        let staleReadAccepted = state.receive(nil, generation: oldGeneration)
        #expect(!staleReadAccepted)
        #expect(state.snapshot?.windows == cached.windows)
        state.clearCache()
        #expect(state.snapshot == nil)
    }

    @Test func snapshotExpiresWithoutFailedReadsOrRequestInvalidationRenewingIt() {
        let data = snapshot([record()])
        var state = MissionControlSnapshotState()
        let generation = state.generation
        let accepted = state.receive(data, generation: generation, now: 10)
        #expect(accepted && state.freshSnapshot(at: 11.99)?.windows.count == 1)
        state.invalidateRequests()
        let late = state.receive(data, generation: generation, now: 11)
        let failed = state.receive(nil, generation: state.generation, now: 11.5)
        #expect(!late && !failed)
        #expect(state.freshSnapshot(at: 12) == nil)
        #expect(state.freshSnapshot(at: 9) == nil)
        let published = state.receive(data, generation: state.generation, now: 12)
        #expect(published && state.freshSnapshot(at: 12)?.windows.count == 1)
        state.clearCache()
        #expect(state.snapshot == nil && state.receivedAt == nil)
    }

    @Test func openingAnimationPreferenceAlsoHonoursReduceMotion() throws {
        let suite = "MissionControlAnimation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MissionControlPresentationSettings.animatesOpening(reduceMotion: false, defaults: defaults))
        #expect(!MissionControlPresentationSettings.animatesOpening(reduceMotion: true, defaults: defaults))
        defaults.set(true, forKey: MissionControlPresentationSettings.skipOpeningAnimationKey)
        #expect(!MissionControlPresentationSettings.animatesOpening(reduceMotion: false, defaults: defaults))
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
        let buttons = view.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }
        #expect(view.subviews.count == 3 && buttons.count == 2)
        #expect(buttons.allSatisfy { $0.image === image && $0.toolTip == nil })
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

extension MissionControlTests {
    @Test func hoverReleaseDepartureAndReentryUseThreeHundredMilliseconds() {
        var lifetime = MissionControlHoverLifetime()
        // Modifier release has no bearing on ownership: trigger/map pointer state does.
        let onTrigger = lifetime.update(inTrigger: true, inMap: false, pressed: false, now: 0)
        #expect(!onTrigger)
        let crossingGap = lifetime.update(inTrigger: false, inMap: false, pressed: false, now: 1)
        #expect(!crossingGap)
        let enteredMap = lifetime.update(inTrigger: false, inMap: true, pressed: false, now: 1.29)
        #expect(!enteredMap)
        let insideMap = lifetime.update(inTrigger: false, inMap: true, pressed: false, now: 3)
        #expect(!insideMap)
        let duringPress = lifetime.update(inTrigger: false, inMap: false, pressed: true, now: 4)
        #expect(!duringPress)
        let departed = lifetime.update(inTrigger: false, inMap: false, pressed: false, now: 5)
        #expect(!departed)
        let beforeDeadline = lifetime.update(inTrigger: false, inMap: false, pressed: false, now: 5.29)
        #expect(!beforeDeadline)
        let afterDeadline = lifetime.update(inTrigger: false, inMap: false, pressed: false, now: 5.31)
        #expect(afterDeadline)
    }

    @Test func pendingSelectionFreezesLayoutAndRejectsRepeatedClicks() {
        var state = MissionControlSelectionState()
        state.press(true)
        #expect(state.pressed)
        let firstSelection = state.begin()
        #expect(firstSelection)
        let repeatedSelection = state.begin()
        #expect(!repeatedSelection)
        state.observeMissionControl(false)
        #expect(state.suppressMissionControl)
        state.finish()
        state.press(false)
        #expect(!state.pending && !state.pressed)
        state.observeMissionControl(true)
        #expect(state.suppressMissionControl)
        state.observeMissionControl(false)
        #expect(!state.suppressMissionControl)
    }

    @Test func escapeAndLifecycleResetDiscardPendingIntent() {
        var state = MissionControlSelectionState()
        state.press(true)
        state.dismiss() // The same path used by Escape.
        #expect(!state.pending && !state.pressed && state.suppressMissionControl)
        state.observeMissionControl(true)
        #expect(state.suppressMissionControl)
        state.observeMissionControl(false)
        #expect(!state.suppressMissionControl)
        let selectionAfterDismissal = state.begin()
        #expect(selectionAfterDismissal)
        state.reset() // Permission loss, shutdown, or screen change.
        #expect(!state.pending && !state.pressed && !state.suppressMissionControl)
    }

    @Test func desktopMappingUsesLiveOrderAndRejectsDeletedOrAmbiguousTargets() {
        let original = catalog()
        #expect(original.selectionIndex(screenID: "primary", desktopID: 2, controlCount: 3) == 1)
        let reordered = SidebarSpaceReader.Catalog(desktops: [
            SidebarDesktop(id: 2, order: 0, number: 1, displayIdentifier: "primary"),
            SidebarDesktop(id: 1, order: 1, number: 2, displayIdentifier: "primary"),
            SidebarDesktop(id: 3, order: 2, number: nil, displayIdentifier: "primary")
        ], activeIDs: [1])
        #expect(reordered.selectionIndex(screenID: "primary", desktopID: 2, controlCount: 3) == 0)
        #expect(reordered.selectionIndex(screenID: "primary", desktopID: 3, controlCount: 3) == 2)
        #expect(reordered.selectionIndex(screenID: "primary", desktopID: 99, controlCount: 3) == nil)
        #expect(reordered.selectionIndex(screenID: "primary", desktopID: 2, controlCount: 2) == nil)
        #expect(reordered.selectionIndex(screenID: "secondary", desktopID: 2, controlCount: 3) == nil)
    }

    @Test func nativeControlsRequireAnExactUniqueDisplayAndCompleteList() {
        struct Node {
            var id: String
            var display: CGDirectDisplayID? = nil
            var children: [Node] = []
        }
        let display = Node(id: "mc.display", display: 22, children: [
            Node(id: "mc.spaces", children: [Node(id: "mc.spaces.list", children: [Node(id: "button")])])
        ])
        func buttons(_ displays: [Node], _ id: CGDirectDisplayID) -> [Node]? {
            MissionControlAXProbe.spaceButtons(root: Node(id: "root", children: displays), owner: .windowManager,
                displayID: id, children: { $0.children }, identifier: { $0.id }, screen: { $0.display })
        }
        #expect(buttons([display], 22)?.count == 1)
        #expect(buttons([display], 23) == nil)
        #expect(buttons([display, display], 22) == nil)
        #expect(buttons([Node(id: "mc.display", display: 22)], 22) == nil)
    }

    @Test func snapshotRetainsExactHandleAndLaunchIdentityWithoutSidebarEntries() throws {
        let handle = AXUIElementCreateApplication(20_001)
        let launch = Date(timeIntervalSince1970: 1)
        var item = record()
        item.focusRequirement = SidebarFocusRequirement(element: handle, launchDate: launch)
        let result = snapshot([item])
        let requirement = try #require(result.focusRequirements[item.id])
        #expect(requirement.matches(element: handle, launchDate: launch))
        #expect(!requirement.matches(element: AXUIElementCreateApplication(20_002), launchDate: launch))
        #expect(!requirement.matches(element: handle, launchDate: Date(timeIntervalSince1970: 2)))
    }

    @Test @MainActor func iconTileAndOuterPaddingHaveSeparateActions() throws {
        _ = NSApplication.shared
        let result = snapshot([record()])
        let layout = try #require(MissionControlLayout.make(snapshot: result, screenID: "primary", screenSize: primary.bounds.size))
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: layout.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = MissionControlView(frame: CGRect(origin: .zero, size: layout.size))
        panel.contentView = view
        var selections: [(UInt64, SidebarWindowID?)] = []
        view.onSelection = { selections.append(($0, $1)) }
        view.configure(layout: layout, applications: result.applications, side: .right,
                       selectableWindows: Set(result.windows.map(\.id)))
        let tile = try #require(layout.tiles.first)
        let icon = try #require(tile.icons.first)
        let point = CGPoint(x: tile.frame.minX + icon.frame.midX, y: tile.frame.minY + icon.frame.midY)
        let iconButton = try #require(view.hitTest(view.convert(point, to: view.superview)) as? NSButton)
        let desktopButton = try #require(iconButton.superview as? NSButton)
        #expect(desktopButton.frame == tile.frame && iconButton.frame == icon.frame)
        #expect(desktopButton.hitTest(CGPoint(x: tile.frame.minX + icon.frame.midX,
                                             y: tile.frame.minY + icon.frame.midY)) === iconButton)
        iconButton.performClick(nil)
        #expect(selections.count == 1 && selections[0].0 == tile.desktop.id && selections[0].1 == icon.windowID)
        let backgroundPoint = CGPoint(x: tile.frame.minX + 1, y: tile.frame.minY + 1)
        let tileButton = try #require(view.hitTest(view.convert(backgroundPoint, to: view.superview)) as? NSButton)
        #expect(tileButton !== iconButton)
        #expect(tileButton === desktopButton)
        #expect(tileButton.isEnabled && tileButton.target === tileButton)
        let action = try #require(tileButton.action)
        #expect(tileButton.responds(to: action))
        tileButton.performClick(nil)
        #expect(selections.count == 2 && selections[1].0 == tile.desktop.id && selections[1].1 == nil)
        #expect(view.hitTest(view.convert(CGPoint(x: 1, y: 1), to: view.superview)) === view)
        #expect(iconButton.title.isEmpty && tileButton.title.isEmpty && !iconButton.isBordered && !tileButton.isBordered)

        func mouseClick(_ button: NSButton, from start: CGPoint, to end: CGPoint) throws {
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: view.convert(start, to: nil), modifierFlags: [], timestamp: 1,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp,
                location: view.convert(end, to: nil), modifierFlags: [], timestamp: 1.1,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            NSApplication.shared.postEvent(up, atStart: true)
            button.mouseDown(with: down)
        }
        try mouseClick(tileButton, from: backgroundPoint, to: backgroundPoint)
        #expect(selections.count == 3 && selections.last?.0 == tile.desktop.id && selections.last?.1 == nil)
        try mouseClick(iconButton, from: point, to: point)
        #expect(selections.count == 4 && selections.last?.1 == icon.windowID)
        try mouseClick(tileButton, from: backgroundPoint, to: point)
        #expect(selections.count == 4)
    }

    @Test @MainActor func releasingOutsidePressedButtonDoesNotSelect() throws {
        let application = NSApplication.shared
        let result = snapshot([record()])
        let layout = try #require(MissionControlLayout.make(snapshot: result, screenID: "primary", screenSize: primary.bounds.size))
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: layout.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = MissionControlView(frame: CGRect(origin: .zero, size: layout.size))
        panel.contentView = view
        var selected = false
        var pressed = false
        view.onSelection = { _, _ in selected = true }
        view.onPress = { pressed = $0 }
        view.configure(layout: layout, applications: result.applications, side: .right,
                       selectableWindows: Set(result.windows.map(\.id)))
        let tile = try #require(layout.tiles.first)
        let backgroundPoint = CGPoint(x: tile.frame.minX + 1, y: tile.frame.minY + 1)
        let button = try #require(view.hitTest(view.convert(backgroundPoint, to: view.superview)) as? NSButton)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: view.convert(CGPoint(x: tile.frame.minX + 1, y: tile.frame.minY + 1), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: -20, y: -20),
            modifierFlags: [], timestamp: 0.1, windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        application.postEvent(up, atStart: true)
        button.mouseDown(with: down)
        #expect(!selected && !pressed)
    }
}

@MainActor
private final class MapActionFixture {
    var current = true
    var windowValid = true
    var mode = MissionControlReading.hidden
    var active: Set<UInt64> = [1]
    var desktops = [SidebarDesktop(id: 1, order: 0, number: 1, displayIdentifier: "screen"),
                    SidebarDesktop(id: 2, order: 1, number: 2, displayIdentifier: "screen")]
    var events: [String] = []
    var press = MissionControlActions.DesktopPress.submitted
    var confirmsSwitch = true
    var confirmsFocus = true
    var onPause: (() -> Void)?
    var onPress: (() -> Void)?
    let selection = MissionControlSelection(screenID: "screen", desktopID: 2, windowID: SidebarWindowID(pid: 100, windowID: 7))

    var environment: MissionControlActions.Environment {
        .init(isCurrent: { self.current },
              catalog: { SidebarSpaceReader.Catalog(desktops: self.desktops, activeIDs: self.active) },
              reading: { self.mode }, validateWindow: { self.windowValid },
              pressDesktop: {
                  self.events.append("press")
                  self.onPress?()
                  if self.press == .submitted && self.confirmsSwitch { self.active = [2]; self.mode = .hidden }
                  return self.press
              }, ensureVisible: {
                  if self.mode == .visible { return .alreadySatisfied }
                  self.events.append("open")
                  self.mode = .visible
                  return .changed
              }, ensureHidden: {
                  if self.mode == .hidden { return .alreadySatisfied }
                  self.events.append("close")
                  self.mode = .hidden
                  return .changed
              }, focusWindow: { self.events.append("focus"); return self.confirmsFocus },
              pause: { self.onPause?() })
    }
}

extension MissionControlTests {
    @Test @MainActor func selectionSwitchesBeforeExactFocusFromBothEntryMethods() async {
        for mode in [MissionControlReading.hidden, .visible] {
            let fixture = MapActionFixture()
            fixture.mode = mode
            let success = await MissionControlActions.perform(fixture.selection, environment: fixture.environment)
            #expect(success)
            #expect(fixture.events == (mode == .hidden ? ["open", "press", "focus"] : ["press", "focus"]))
        }
    }

    @Test @MainActor func currentAndEmptyDesktopSelectionDoesNotRequireAWindow() async {
        let fixture = MapActionFixture()
        var desktop = fixture.selection
        desktop.windowID = nil
        fixture.windowValid = false
        #expect(await MissionControlActions.perform(desktop, environment: fixture.environment))
        #expect(fixture.events == ["open", "press"])
        fixture.events = []
        #expect(await MissionControlActions.perform(desktop, environment: fixture.environment))
        #expect(fixture.events.isEmpty)
    }

    @Test @MainActor func staleWindowDeletedDesktopAndDisconnectedScreenRejectBeforeMutation() async {
        for failure in 0..<3 {
            let fixture = MapActionFixture()
            if failure == 0 { fixture.windowValid = false }
            if failure == 1 { fixture.desktops.removeLast() }
            if failure == 2 { fixture.current = false }
            #expect(!(await MissionControlActions.perform(fixture.selection, environment: fixture.environment)))
            #expect(fixture.events.isEmpty)
        }
    }

    @Test @MainActor func unsupportedControlsCleanUpOnlyMissionControlOpenedByTheAction() async {
        for mode in [MissionControlReading.hidden, .visible] {
            let fixture = MapActionFixture()
            fixture.mode = mode
            fixture.press = .rejected
            #expect(!(await MissionControlActions.perform(fixture.selection, environment: fixture.environment)))
            #expect(fixture.events == (mode == .hidden ? ["open", "press", "close"] : ["press"]))
            #expect(fixture.mode == mode)
        }
    }

    @Test @MainActor func acceptedPressWithoutDesktopConfirmationNeverFocusesOrRetries() async {
        let fixture = MapActionFixture()
        fixture.confirmsSwitch = false
        #expect(!(await MissionControlActions.perform(fixture.selection, environment: fixture.environment)))
        #expect(fixture.events == ["open", "press", "close"])
    }

    @Test @MainActor func staleWindowAfterDesktopSwitchAndUnconfirmedFocusFailQuietly() async {
        let fixture = MapActionFixture()
        fixture.onPress = { fixture.windowValid = false }
        #expect(!(await MissionControlActions.perform(fixture.selection, environment: fixture.environment)))
        #expect(!fixture.events.contains("focus"))
        let unconfirmed = MapActionFixture()
        unconfirmed.confirmsFocus = false
        #expect(!(await MissionControlActions.perform(unconfirmed.selection, environment: unconfirmed.environment)))
    }

    @Test @MainActor func permissionLossDuringTransitionStopsPendingWork() async {
        let fixture = MapActionFixture()
        fixture.press = .notReady
        fixture.onPause = { fixture.current = false }
        #expect(!(await MissionControlActions.perform(fixture.selection, environment: fixture.environment)))
        #expect(!fixture.events.contains("focus"))
        #expect(fixture.events.filter { $0 == "open" }.count == 1)
    }
}

extension MissionControlTests {
    @Test func coldHoverPreviewWaitsForFirstPanelButDoesNotStayOpenForever() {
        var lifetime = MissionControlHoverLifetime()
        lifetime.beginLoading(now: 0)
        let loading = lifetime.update(inTrigger: false, inMap: false, pressed: false, now: 0.5)
        #expect(!loading)
        lifetime.didPresent()
        let inside = lifetime.update(inTrigger: false, inMap: true, pressed: false, now: 0.6)
        let departed = lifetime.update(inTrigger: false, inMap: false, pressed: false, now: 1)
        let dismissed = lifetime.update(inTrigger: false, inMap: false, pressed: false, now: 1.31)
        #expect(!inside && !departed && dismissed)

        lifetime.beginLoading(now: 2)
        let stalled = lifetime.update(inTrigger: false, inMap: false, pressed: false, now: 4)
        let timeout = lifetime.update(inTrigger: false, inMap: false, pressed: false, now: 4.31)
        #expect(!stalled && timeout)
    }

    @Test @MainActor func currentDesktopInMissionControlExitsWithoutFocusingAWindow() async {
        let fixture = MapActionFixture()
        fixture.mode = .visible
        fixture.active = [2]
        var desktop = fixture.selection
        desktop.windowID = nil
        #expect(await MissionControlActions.perform(desktop, environment: fixture.environment))
        #expect(fixture.events == ["close"])
    }

    @Test @MainActor func escapeCancellationDoesNotSubmitAnotherSystemTransition() async {
        let fixture = MapActionFixture()
        fixture.press = .notReady
        let task = Task { await MissionControlActions.perform(fixture.selection, environment: fixture.environment) }
        fixture.onPause = { task.cancel() }
        #expect(!(await task.value))
        #expect(fixture.events == ["open", "press"])
    }

    @Test @MainActor func failedSelectionDoesNotCloseAfterDesktopContextChanges() async {
        let fixture = MapActionFixture()
        fixture.press = .rejected
        fixture.onPress = { fixture.active = [2] }
        #expect(!(await MissionControlActions.perform(fixture.selection, environment: fixture.environment)))
        #expect(fixture.events == ["open", "press"])
    }
}

@MainActor
private final class MapLauncherFixture {
    var mode = MissionControlReading.hidden
    var current = true
    var time: TimeInterval = 0
    var requests = 0
    var acceptsLaunch = true
    var completesLaunch = true
    var launchSucceeds = true
    var changesState = true
    var callback: (@MainActor (Bool) -> Void)?
    var onPause: (() -> Void)?

    var environment: MissionControlSystemLauncher.Environment {
        .init(reading: { self.mode }, isCurrent: { self.current }, requestLaunch: { callback in
            self.requests += 1
            self.callback = callback
            guard self.acceptsLaunch else { return false }
            if self.changesState { self.mode = self.mode == .hidden ? .visible : .hidden }
            if self.completesLaunch { callback(self.launchSucceeds) }
            return true
        }, now: { self.time }, pause: {
            self.time += 0.1
            self.onPause?()
        })
    }
}

extension MissionControlTests {
    @Test @MainActor func launcherObservesStateAndSendsOneRequestPerTransition() async {
        let fixture = MapLauncherFixture()
        let launcher = MissionControlSystemLauncher()
        #expect(await launcher.ensureHidden(environment: fixture.environment) == .alreadySatisfied)
        #expect(fixture.requests == 0)
        #expect(await launcher.ensureVisible(environment: fixture.environment) == .changed)
        #expect(fixture.requests == 1)
        #expect(await launcher.ensureVisible(environment: fixture.environment) == .alreadySatisfied)
        #expect(fixture.requests == 1)
        #expect(await launcher.ensureHidden(environment: fixture.environment) == .changed)
        #expect(fixture.requests == 2 && !launcher.automaticLaunchesDisabled)
    }

    @Test @MainActor func launchCallbackIsNotProofOfMissionControlVisibility() async {
        let fixture = MapLauncherFixture()
        fixture.changesState = false
        let launcher = MissionControlSystemLauncher()
        #expect(await launcher.ensureVisible(environment: fixture.environment) == .timedOut)
        #expect(fixture.time >= 2 && fixture.requests == 1)
        #expect(await launcher.ensureVisible(environment: fixture.environment) == .disabled)
        #expect(fixture.requests == 1)
        #expect(await launcher.ensureHidden(environment: fixture.environment) == .alreadySatisfied)
    }

    @Test @MainActor func unavailableStateAndLaunchFailuresDoNotRetry() async {
        let unavailable = MapLauncherFixture()
        unavailable.mode = .unavailable
        #expect(await MissionControlSystemLauncher().ensureVisible(environment: unavailable.environment) == .unavailable)
        #expect(unavailable.requests == 0)
        for rejectedRequest in [true, false] {
            let fixture = MapLauncherFixture()
            fixture.acceptsLaunch = !rejectedRequest
            fixture.launchSucceeds = false
            fixture.changesState = false
            let launcher = MissionControlSystemLauncher()
            #expect(await launcher.ensureVisible(environment: fixture.environment) == .launchFailed)
            #expect(launcher.automaticLaunchesDisabled)
            #expect(await launcher.ensureVisible(environment: fixture.environment) == .disabled)
            #expect(fixture.requests == 1)
        }
    }

    @Test @MainActor func lateLaunchCallbackCannotResumeTimedOutSelection() async {
        let fixture = MapLauncherFixture()
        fixture.completesLaunch = false
        let launcher = MissionControlSystemLauncher()
        #expect(await launcher.ensureVisible(environment: fixture.environment) == .timedOut)
        fixture.callback?(true)
        #expect(launcher.automaticLaunchesDisabled && fixture.requests == 1)
        #expect(await launcher.ensureHidden(environment: fixture.environment) == .disabled)
        #expect(fixture.requests == 1)
    }

    @Test @MainActor func cancelledLaunchIgnoresLateCompletionAndDisablesFurtherLaunches() async {
        let fixture = MapLauncherFixture()
        fixture.completesLaunch = false
        fixture.changesState = false
        fixture.onPause = { fixture.current = false }
        let launcher = MissionControlSystemLauncher()
        #expect(await launcher.ensureVisible(environment: fixture.environment) == .cancelled)
        fixture.current = true
        fixture.callback?(true)
        #expect(await launcher.ensureVisible(environment: fixture.environment) == .disabled)
        #expect(fixture.requests == 1)
    }
}
