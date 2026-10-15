import AppKit
import Testing
@testable import octopus

struct WindowTabGroupTests {
    @Test @MainActor func sidebarFocusCompletionReportsTheRaiseOnceAndCannotCompleteAfterCancellation() {
        let target = SidebarWindowID(pid: 43, windowID: 7)
        var results: [Bool] = []
        let action = SidebarPendingAction(frontmostPID: 42, focusTarget: target, completion: { results.append($0) })
        #expect(action.focusTarget == target)
        action.completeFocus(true)
        action.completeFocus(false)
        #expect(results == [true])
        var cancelledResults: [Bool] = []
        let cancelled = SidebarPendingAction(frontmostPID: 42, focusTarget: target, completion: { cancelledResults.append($0) })
        cancelled.cancel()
        cancelled.completeFocus(true)
        #expect(cancelledResults.isEmpty)
    }

    @Test func anActiveAppAndFocusedWindowDoNotProveTheTabIsOnTop() {
        let chosen = SidebarWindowID(pid: 43, windowID: 7)
        let covering = SidebarWindowID(pid: 42, windowID: 8)
        let members: Set<SidebarWindowID> = [chosen, covering]
        #expect(WindowControlAccess.frontmostTab(in: [covering, chosen], members: members) == covering)
        var reads = 0, waits = 0
        let confirmed = WindowTabGroupService.confirmFocus(canContinue: { true }, readConfirmed: {
            reads += 1
            let order = reads == 1 ? [covering, chosen] : [chosen, covering]
            return WindowControlAccess.frontmostTab(in: order, members: members) == chosen
        }, wait: { waits += 1 })
        #expect(confirmed && reads == 2 && waits == 1)
    }

    @Test func aWindowThatStaysBehindNeverReportsSuccessfulTabSwitching() {
        var reads = 0
        let confirmed = WindowTabGroupService.confirmFocus(canContinue: { true }, readConfirmed: {
            reads += 1; return false
        }, wait: {}, maximumReads: 3)
        #expect(!confirmed && reads == 3)
        let cancelled = WindowTabGroupService.confirmFocus(canContinue: { false }, readConfirmed: {
            reads += 1; return true
        }, wait: {})
        #expect(!cancelled && reads == 3)
    }
    private let scope = WindowLayoutScope(displayID: "display", spaceID: 1)
    private let shared = CGRect(x: 100, y: 100, width: 700, height: 500)

    private func window(_ number: UInt32, pid: pid_t = 42, frame: CGRect? = nil,
                        generation: UInt64 = 1, minimum: CGSize = .zero,
                        blocked: Bool = false, otherScope: WindowLayoutScope? = nil,
                        hidden: Bool = false, minimized: Bool = false) -> WindowLayoutWindow {
        WindowLayoutWindow(id: WindowLayoutIdentity(window: SidebarWindowID(pid: pid, windowID: number), generation: generation),
            scope: otherScope ?? scope, frame: frame ?? shared, minimum: minimum, minimumReported: minimum != .zero,
            canMove: true, canResize: true, hidden: hidden, minimized: minimized, blocked: blocked, recency: 0, stackOrder: 0)
    }

    private func moved(_ original: WindowLayoutWindow, to frame: CGRect) -> WindowLayoutWindow {
        window(original.id.window.windowID, pid: original.id.window.pid, frame: frame,
            generation: original.id.generation, minimum: original.minimum, blocked: original.blocked, otherScope: original.scope)
    }

    @Test func hoverNeedsAContinuousPauseOverTheSameOtherWindow() {
        let source = SidebarWindowID(pid: 42, windowID: 1)
        let first = SidebarWindowID(pid: 43, windowID: 2)
        let second = SidebarWindowID(pid: 44, windowID: 3)
        var hover = WindowTabHover(source: source)
        hover.update(target: first, at: 10)
        #expect(!hover.isReady(at: 10.59))
        #expect(hover.isReady(at: 10.61))
        hover.update(target: second, at: 10.62)
        #expect(!hover.isReady(at: 10.7))
        hover.update(target: nil, at: 11)
        #expect(!hover.isReady(at: 20))
        hover.update(target: source, at: 21)
        #expect(!hover.isReady(at: 30))
    }

    @Test func centreZoneLeavesTheWindowEdgesForOrdinaryMovement() {
        let centre = WindowTabGeometry.centre(of: shared)
        #expect(centre.contains(CGPoint(x: shared.midX, y: shared.midY)))
        #expect(!centre.contains(CGPoint(x: shared.minX + 5, y: shared.midY)))
        #expect(!centre.contains(CGPoint(x: shared.midX, y: shared.minY + 5)))
    }

    @Test func groupingAlignsDifferentAppsWithoutRewritingAnAlreadyAlignedTarget() {
        let target = window(1)
        let source = window(2, pid: 43, frame: CGRect(x: 500, y: 400, width: 400, height: 300))
        var live = [target.id: target, source.id: source]
        var writes: [WindowLayoutIdentity] = []
        let result = WindowTabGroupService.align([target, source], to: shared, scope: scope,
            canContinue: { true }, read: { live[$0.id] }, write: { window, frame in
                writes.append(window.id)
                live[window.id] = moved(window, to: frame)
                return .placed(frame, adjusted: false)
            })
        #expect(result.reason == nil)
        #expect(result.windows.count == 2)
        #expect(writes == [source.id])
        #expect(result.windows.allSatisfy { $0.frame == shared })
    }

    @Test(arguments: [pid_t(42), pid_t(44)])
    func addingAThirdWindowRetainsBothExistingMembers(_ pid: pid_t) {
        let existing = [window(1), window(2, pid: 43)]
        let joining = window(3, pid: pid, frame: shared.offsetBy(dx: 300, dy: 100))
        var live = Dictionary(uniqueKeysWithValues: (existing + [joining]).map { ($0.id, $0) })
        var writes: [WindowLayoutIdentity] = []
        let result = WindowTabGroupService.align(existing + [joining], to: shared, scope: scope,
            canContinue: { true }, read: { live[$0.id] }, write: { window, frame in
                writes.append(window.id)
                live[window.id] = moved(window, to: frame)
                return .placed(frame, adjusted: false)
            })
        #expect(result.reason == nil)
        #expect(result.windows.map(\.id) == (existing + [joining]).map(\.id))
        #expect(writes == [joining.id])
    }

    @Test func stripGeometryFollowsMovedAndSnappedFramesAndProtectsTrafficLights() {
        let work = CGRect(x: -1200, y: 0, width: 1200, height: 900)
        let moved = CGRect(x: -1000, y: 100, width: 500, height: 600)
        let strip = WindowTabGeometry.stripFrame(window: moved, workArea: work)
        #expect(strip == CGRect(x: moved.minX, y: moved.minY - 30, width: moved.width, height: 30))
        let snapped = CGRect(x: work.midX, y: work.minY, width: work.width / 2, height: work.height)
        let top = WindowTabGeometry.stripFrame(window: snapped, workArea: work)
        #expect(top.minY == snapped.minY && top.minX == snapped.minX + 80)
        #expect(top.maxX == snapped.maxX && top.width == snapped.width - 80)
    }

    @Test func groupMovePreviewKeepsItsSizeAndStaysOnTheCurrentDisplay() {
        let area = CGRect(x: -1200, y: 0, width: 1200, height: 900)
        let original = CGRect(x: -900, y: 100, width: 700, height: 500)
        var gesture = WindowTabMoveGesture(frame: original, pointer: CGPoint(x: -800, y: 80), workArea: area)
        gesture.update(pointer: CGPoint(x: -798, y: 81))
        #expect(!gesture.moved && gesture.frame == original)
        gesture.update(pointer: CGPoint(x: 500, y: -300))
        #expect(gesture.moved && area.contains(gesture.frame))
        #expect(gesture.frame.size == original.size)
        #expect(gesture.frame.origin == CGPoint(x: -700, y: 0))
    }

    @Test func movingAGroupPlacesItsSelectedWindowFirstAndReturnsTheOriginalMemberOrder() {
        let members = [window(1), window(2, pid: 43)]
        let frame = shared.offsetBy(dx: 120, dy: 80)
        var live = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        var writes: [WindowLayoutIdentity] = []
        let result = WindowTabGroupService.move(members, selected: members[1].id, from: shared, to: frame, scope: scope,
            canContinue: { true }, read: { live[$0.id] }, write: { window, target in
                writes.append(window.id)
                live[window.id] = moved(window, to: target)
                return .placed(target, adjusted: false)
            })
        #expect(result.reason == nil)
        #expect(writes == [members[1].id, members[0].id])
        #expect(result.windows.map(\.id) == members.map(\.id))
        #expect(result.windows.allSatisfy { $0.frame == frame })
    }

    @Test func staleOrCancelledGroupMovesNeverContinueWithAnotherWindow() {
        let members = [window(1), window(2, pid: 43)]
        let target = shared.offsetBy(dx: 100, dy: 0)
        var writes = 0
        let stale = WindowTabGroupService.move(members, selected: members[0].id,
            from: shared.offsetBy(dx: 20, dy: 0), to: target, scope: scope,
            canContinue: { true }, read: { $0 }, write: { _, frame in writes += 1; return .placed(frame, adjusted: false) })
        #expect(stale.reason != nil && !stale.placementFailed && writes == 0)
        var current = members[0], cancelled = false
        let interrupted = WindowTabGroupService.move(members, selected: members[0].id,
            from: shared, to: target, scope: scope, canContinue: { !cancelled },
            read: { $0.id == current.id ? current : $0 }, write: { window, frame in
                writes += 1
                current = moved(window, to: frame)
                cancelled = true
                return .placed(frame, adjusted: false)
            })
        #expect(interrupted.reason != nil && !interrupted.placementFailed && writes == 1)
    }

    @Test func tabShortcutWrapsAcrossExactWindowsIncludingTheSameApp() {
        let members = [window(1), window(2), window(3, pid: 43)]
        let group = WindowTabGroup(id: UUID(), members: members.map {
            WindowTabMember(window: $0, originalFrame: shared, title: "Document")
        }, selected: members[0].id, frame: shared, scope: scope)
        #expect(group.neighbour(of: members[0].id, direction: 1) == members[1].id)
        #expect(group.neighbour(of: members[0].id, direction: -1) == members[2].id)
        #expect(group.neighbour(of: members[2].id, direction: 1) == members[0].id)
        #expect(group.neighbour(of: window(9).id, direction: 1) == nil)
        #expect(WindowTabShortcut.direction(keyCode: 48, modifiers: .control) == 1)
        #expect(WindowTabShortcut.direction(keyCode: 48, modifiers: [.control, .shift]) == -1)
        #expect(WindowTabShortcut.direction(keyCode: 48, modifiers: [.control, .option]) == nil)
        #expect(WindowTabShortcut.direction(keyCode: 48, modifiers: .command) == nil)
        #expect(WindowTabShortcut.direction(keyCode: 49, modifiers: .control) == nil)
    }

    @Test func tabShortcutPassesThroughOutsideGroupsAndConsumesOnlyOneSwitchPerPress() {
        var session = WindowTabShortcutSession()
        let ungrouped = session.route(.keyDown, keyCode: 48, modifiers: .control, repeating: false, window: nil)
        #expect(ungrouped == .pass)
        let window = SidebarWindowID(pid: 43, windowID: 2)
        let first = session.route(.keyDown, keyCode: 48, modifiers: .control, repeating: false, window: window)
        #expect(first == .cycle(window, 1))
        let repeatKey = session.route(.keyDown, keyCode: 48, modifiers: .control, repeating: true, window: nil)
        #expect(repeatKey == .consume)
        let release = session.route(.keyUp, keyCode: 48, modifiers: [], repeating: false, window: nil)
        #expect(release == .consume && !session.capturedTab)
        let next = session.route(.keyDown, keyCode: 48, modifiers: [.control, .shift], repeating: false, window: window)
        #expect(next == .cycle(window, -1))
        session.cancel()
        let cancelledRelease = session.route(.keyUp, keyCode: 48, modifiers: [], repeating: false, window: nil)
        #expect(cancelledRelease == .pass)
    }

    @Test func groupingRejectsDialogsSizeLimitsAndOtherDesktopsBeforeAnyWrite() {
        let target = window(1)
        let rejected = [window(2, blocked: true), window(2, minimum: CGSize(width: 800, height: 200)),
                        window(2, otherScope: WindowLayoutScope(displayID: "display", spaceID: 2))]
        for source in rejected {
            var writes = 0
            let result = WindowTabGroupService.align([target, source], to: shared, scope: scope,
                canContinue: { true }, read: { $0 }, write: { _, frame in writes += 1; return .placed(frame, adjusted: false) })
            #expect(result.reason != nil)
            #expect(result.placementFailed == (source.minimum.width > shared.width))
            #expect(writes == 0)
        }
    }

    @Test func reusedWindowIDAndExternalMovementRejectBeforeWrites() {
        let source = window(1)
        let target = window(2)
        let changed = [window(1, generation: 2), window(1, frame: shared.offsetBy(dx: 20, dy: 0))]
        for replacement in changed {
            var writes = 0
            let result = WindowTabGroupService.align([source, target], to: shared, scope: scope,
                canContinue: { true }, read: { $0.id == source.id ? replacement : $0 },
                write: { _, frame in writes += 1; return .placed(frame, adjusted: false) })
            #expect(result.reason != nil)
            #expect(!result.placementFailed)
            #expect(writes == 0)
        }
    }

    @Test func refusedResizeStopsWithoutRetriesOrRollback() {
        let target = window(1, frame: shared.offsetBy(dx: 30, dy: 0))
        let source = window(2, pid: 43, frame: shared.offsetBy(dx: 200, dy: 0))
        var live = [target.id: target, source.id: source]
        var writes: [WindowLayoutIdentity] = []
        let result = WindowTabGroupService.align([target, source], to: shared, scope: scope,
            canContinue: { true }, read: { live[$0.id] }, write: { window, frame in
                writes.append(window.id)
                if window.id == source.id { return .failed("Refused") }
                live[window.id] = moved(window, to: frame)
                return .placed(frame, adjusted: false)
            })
        #expect(result.reason != nil)
        #expect(result.placementFailed)
        #expect(writes == [target.id, source.id])
        #expect(live[target.id]?.frame == shared)
        #expect(live[source.id]?.frame == source.frame)
    }

    @Test func cancellationDuringAWriteDoesNotContinueWithOtherWindows() {
        let windows = [window(1, frame: shared.offsetBy(dx: 100, dy: 0)), window(2, frame: shared.offsetBy(dx: 200, dy: 0))]
        var cancelled = false
        var writes = 0
        let result = WindowTabGroupService.align(windows, to: shared, scope: scope,
            canContinue: { !cancelled }, read: { $0 }, write: { _, frame in
                writes += 1
                cancelled = true
                return .placed(frame, adjusted: false)
            })
        #expect(result.reason != nil)
        #expect(writes == 1)
    }

    @Test func removingATabKeepsDistinctWindowsFromTheSameAppAndSelectsANeighbour() {
        let windows = [window(1), window(2), window(3)]
        var group = WindowTabGroup(id: UUID(), members: windows.map {
            WindowTabMember(window: $0, originalFrame: $0.frame, title: "Document")
        }, selected: windows[1].id, frame: shared, scope: scope)
        group.remove(windows[1].id)
        #expect(group.members.map(\.window.id) == [windows[0].id, windows[2].id])
        #expect(group.selected == windows[2].id)
        group.remove(windows[2].id)
        #expect(group.selected == windows[0].id)
    }

    @Test func detachingRestoresOriginalSizeWithinTheCurrentDisplay() {
        let work = CGRect(x: -1200, y: -300, width: 1000, height: 800)
        let original = CGRect(x: 200, y: 200, width: 600, height: 400)
        let detached = WindowTabGeometry.detachedFrame(original: original, at: CGPoint(x: -250, y: 400), workArea: work)
        #expect(detached.size == original.size)
        #expect(work.contains(detached))
        let reserved = WindowTabGeometry.groupFrame(target: work, workArea: work)
        #expect(reserved.minY == work.minY + WindowTabGeometry.stripHeight)
        #expect(reserved.maxY == work.maxY)
    }

    @Test func groupingRequiresBothAdjustmentAndMostRecentSelection() throws {
        let name = "WindowTabGroupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(WindowLayoutSettings.tabGroupingEnabled(in: defaults))
        defaults.set(WindowLayoutSelection.allNormal.rawValue, forKey: WindowLayoutSettings.selectionKey)
        #expect(!WindowLayoutSettings.tabGroupingEnabled(in: defaults))
        defaults.set(WindowLayoutSelection.mostRecent.rawValue, forKey: WindowLayoutSettings.selectionKey)
        defaults.set(false, forKey: WindowLayoutSettings.enabledKey)
        #expect(!WindowLayoutSettings.tabGroupingEnabled(in: defaults))
    }

    @Test func readingTwoTabStateFlagsDoesNotAssumeTheEightAttributeFrameQuery() throws {
        let flags = try #require(WindowControlAccess.decodeBulkAttributes(
            [NSNumber(value: false), NSNumber(value: true)], expectedCount: 2, requiredIndices: []))
        #expect(flags.count == 2)
        #expect(flags[0].optionalBool == false && flags[1].optionalBool == true)
        let unsupported = try #require(WindowControlAccess.decodeBulkAttributes(
            [NSNull(), NSNumber(value: false)], expectedCount: 2, requiredIndices: []))
        #expect(unsupported[0].optionalBool == false)
        #expect(WindowControlAccess.decodeBulkAttributes([NSNumber(value: false)], expectedCount: 2, requiredIndices: []) == nil)
        #expect(WindowControlAccess.decodeBulkAttributes([NSNumber(value: false), NSNumber(value: true)],
            expectedCount: 2, requiredIndices: [6]) == nil)
    }


    @Test func aTabClickReadsOnlyTheChosenWindowAndDoesNotRearrangeTheGroup() {
        let chosen = window(7, pid: 43)
        let changed = window(7, pid: 43, frame: shared.offsetBy(dx: 30, dy: 20))
        var reads: [WindowLayoutIdentity] = []
        let selected = WindowTabGroupService.selection(chosen, scope: scope, canContinue: { true }, read: {
            reads.append($0.id)
            return changed
        })
        #expect(reads == [chosen.id])
        #expect(selected?.frame == changed.frame)
    }

    @Test func hiddenTabsAndParentsWithDialogsCanBeFocusedWithoutResizingThem() {
        let expected = window(7, pid: 43)
        for actual in [window(7, pid: 43, hidden: true), window(7, pid: 43, blocked: true)] {
            let selected = WindowTabGroupService.selection(expected, scope: scope, canContinue: { true }, read: { _ in actual })
            #expect(selected?.id == expected.id)
        }
    }

    @Test func tabSelectionRejectsReusedIDsMinimisedWindowsAndMovedDesktops() {
        let expected = window(7, pid: 43)
        for actual in [window(7, pid: 43, generation: 2), window(7, pid: 43, minimized: true),
                       window(7, pid: 43, otherScope: WindowLayoutScope(displayID: "display", spaceID: 2))] {
            #expect(WindowTabGroupService.selection(expected, scope: scope, canContinue: { true }, read: { _ in actual }) == nil)
        }
        var reads = 0
        #expect(WindowTabGroupService.selection(expected, scope: scope, canContinue: { false }, read: { _ in
            reads += 1; return expected
        }) == nil)
        #expect(reads == 0)
    }




    @Test @MainActor func nativeStripHighlightsAndRoutesActionsToTheExactWindow() throws {
        let native = NSWindow(contentRect: shared, styleMask: [.titled], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.orderFront(nil)
        let other = NSWindow(contentRect: shared.offsetBy(dx: 40, dy: 40), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFront(nil)
        let panel = WindowTabStripPanel(groupID: UUID())
        defer { panel.close(); native.close(); other.close() }
        let first = window(UInt32(native.windowNumber), pid: ProcessInfo.processInfo.processIdentifier)
        let second = window(UInt32(other.windowNumber), pid: ProcessInfo.processInfo.processIdentifier)
        let members = [first, second].map { WindowTabMember(window: $0, originalFrame: shared, title: "Document") }
        var group = WindowTabGroup(id: UUID(), members: members, selected: second.id, frame: shared, scope: scope)
        var selected: WindowLayoutIdentity?
        var detached: WindowLayoutIdentity?
        var closed: WindowLayoutIdentity?
        panel.onSelect = { selected = $0 }
        panel.onDetach = { detached = $0; #expect($1 == nil) }
        panel.onClose = { closed = $0 }
        // Order relative to the real host window; the first tab is initially active.
        group.selected = first.id
        panel.show(group, workArea: CGRect(x: 0, y: 0, width: 1600, height: 1200))
        func buttons(in view: NSView) -> [NSButton] {
            if let button = view as? NSButton { return [button] }
            return view.subviews.flatMap { buttons(in: $0) }
        }
        let content = try #require(panel.contentView)
        let grip = try #require(content.subviews.last)
        #expect(grip.toolTip == "Drag to move the grouped windows")
        #expect(content.hitTest(CGPoint(x: 14, y: 14)) === grip)
        let tabs = buttons(in: content)
        #expect(tabs.count == 2)
        #expect(tabs[0].state == .on && tabs[1].state == .off)
        #expect(!panel.canBecomeKey && panel.level == .normal)
        let close = try #require(tabs[0].subviews.compactMap { $0 as? NSButton }.first)
        #expect(close.image != nil)
        #expect(tabs[0].bounds.contains(close.frame))
        let tabContainer = try #require(tabs[0].superview)
        let closeHitPoint = tabs[0].convert(CGPoint(x: close.frame.midX, y: close.frame.midY), to: tabContainer)
        #expect(tabs[0].hitTest(closeHitPoint) === close)
        #expect(close.accessibilityIdentifier() == "window-tab-close-\(first.id.window.pid)-\(first.id.window.windowID)")
        close.performClick(nil)
        #expect(closed == first.id && selected == nil)
        #expect(group.members.count == 2) // A close request alone never removes membership.
        closed = nil
        tabs[1].performClick(nil)
        #expect(selected == second.id)
        let menu = try #require(tabs[1].menu)
        #expect(menu.items.map(\.title) == ["Move out", "Close window"])
        for item in menu.items {
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        }
        #expect(detached == second.id && closed == second.id)
        group.selected = second.id
        panel.show(group, workArea: CGRect(x: 0, y: 0, width: 1600, height: 1200))
        let updated = buttons(in: content)
        #expect(updated[0].state == .off && updated[1].state == .on)
        // Narrow strips scroll to the selected tab rather than hiding it off the end.
        group.frame.size.width = 160
        group.selected = first.id
        panel.show(group, workArea: CGRect(x: 0, y: 0, width: 1600, height: 1200))
        group.selected = second.id
        panel.show(group, workArea: CGRect(x: 0, y: 0, width: 1600, height: 1200))
        let scroll = try #require(content.subviews.first as? NSScrollView)
        #expect(scroll.contentView.bounds.minX > 0)
        let expectedStrip = WindowTabGeometry.stripFrame(window: group.frame,
            workArea: CGRect(x: 0, y: 0, width: 1600, height: 1200))
        #expect(panel.frame == SidebarPlacementGeometry.flip(expectedStrip, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0))
    }
}
