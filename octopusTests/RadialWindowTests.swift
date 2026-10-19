import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI
import Testing
@testable import octopus

@MainActor
struct RadialWindowTests {
    private func items(_ count: Int) -> [RadialWindowItem] {
        (0..<count).map { RadialWindowItem(id: SidebarWindowID(pid: 20_000, windowID: UInt32($0 + 1)),
            applicationName: "App", title: "Window \($0 + 1)", icon: nil) }
    }

    private func point(_ angle: Double, _ radius: CGFloat) -> CGPoint {
        let offset = RadialWindowGeometry.offset(angle: angle, radius: radius)
        return CGPoint(x: offset.width, y: -offset.height)
    }

    @Test(arguments: [0, 1, 8, 9, 13, 14, 45])
    func everyWindowHasExactlyOneStableSlot(count: Int) {
        let model = RadialWindowModel(items: items(count))
        #expect(model.ringCount == min(count, 8))
        #expect(model.hasOverflow == (count > 8))
        #expect(model.mainCount + model.overflowCount == count)
        #expect(model.selection == .none)
        if count > 8 {
            #expect(model.pageRange == 7..<min(count, 13))
            #expect(model.pageCount == (count - 7 + 5) / 6)
        }
    }

    @Test func moreStaysOpenAcrossGapAndReleaseOnMoreSelectsNothing() {
        let model = RadialWindowModel(items: items(15))
        model.updatePointer(point(315, 106), centre: .zero)
        #expect(model.selectsMore && model.expanded && model.selectedItem == nil)
        model.updatePointer(point(315, 153), centre: .zero)
        #expect(model.selection == .none && model.expanded)
        // Six outer slots: their centres are 260, 282, 304, 326, 348, and 370 degrees.
        model.updatePointer(point(304, 185), centre: .zero)
        #expect(model.selectedItem?.id == items(15)[9].id)
        model.updatePointer(point(315, 106), centre: .zero)
        #expect(model.selectsMore && model.selectedItem == nil)
        model.updatePointer(.zero, centre: .zero)
        #expect(!model.expanded && model.selection == .none)
    }

    @Test func movingWithinOneSliceDoesNotRepublishTheSameHoverState() {
        let model = RadialWindowModel(items: items(10))
        var updates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }
        model.updatePointer(point(0, 100), centre: .zero)
        #expect(updates == 1 && model.selection == .ring(0))
        for angle in [1.0, 4.0, 8.0, 3.0] {
            model.updatePointer(point(angle, 110), centre: .zero)
        }
        #expect(updates == 1)
        model.updatePointer(point(45, 106), centre: .zero)
        #expect(updates == 2 && model.selection == .ring(1))
        model.updatePointer(.zero, centre: .zero)
        #expect(updates == 3 && model.selection == .none)
    }

    @Test func handCursorTargetsMatchEnabledSlicesAndExcludeCentreAndGaps() {
        let initial = items(10)
        let model = RadialWindowModel(items: initial)
        func offset(_ angle: Double, _ radius: CGFloat) -> CGVector {
            let value = RadialWindowGeometry.offset(angle: angle, radius: radius)
            return CGVector(dx: value.width, dy: value.height)
        }
        #expect(model.hasCursorTarget(at: offset(0, 106)))
        #expect(!model.hasCursorTarget(at: .zero))
        #expect(!model.hasCursorTarget(at: offset(22.5, 106)))
        #expect(!model.hasCursorTarget(at: offset(0, 300)))
        #expect(!model.hasCursorTarget(at: offset(315, 185)))
        #expect(model.hasCursorTarget(at: offset(315, 106)))
        model.updatePointer(point(315, 106), centre: .zero)
        #expect(model.hasCursorTarget(at: offset(315, 185)))
        model.reconcile(availableIDs: Set(initial.dropFirst().map(\.id)))
        #expect(!model.hasCursorTarget(at: offset(0, 106)))
        #expect(RadialWindowModel(items: []).hasCursorTarget(at: offset(0, 106)) == false)
    }

    @Test func nativeHoverSetsHandBeforeClickWithoutMakingPanelKey() throws {
        let originalCursor = NSCursor.current
        let panel = RadialWindowPanel(model: RadialWindowModel(items: items(3)))
        panel.setFrameOrigin(CGPoint(x: 200, y: 200))
        let host = try #require(panel.contentView as? NSHostingView<RadialWindowView>)
        defer { panel.contentView = nil; panel.close(); originalCursor.set() }
        panel.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.updateTrackingAreas()
        #expect(!panel.isKeyWindow)
        #expect(host.trackingAreas.contains {
            ($0.owner as? NSView) === host && $0.options.contains([.activeAlways, .mouseMoved, .enabledDuringMouseDrag])
        })
        func hover(_ angle: Double, _ radius: CGFloat) throws {
            let offset = RadialWindowGeometry.offset(angle: angle, radius: radius)
            let screenPoint = CGPoint(x: panel.frame.midX + offset.width, y: panel.frame.midY - offset.height)
            let location = panel.convertFromScreen(CGRect(origin: screenPoint, size: .zero)).origin
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))
            host.mouseMoved(with: event)
        }
        try hover(0, 106)
        #expect(NSCursor.current === NSCursor.pointingHand)
        #expect(!panel.isKeyWindow)
        try hover(0, 0)
        #expect(NSCursor.current === NSCursor.arrow)
        try hover(60, 106)
        #expect(NSCursor.current === NSCursor.arrow)
        try hover(0, 106)
        panel.contentView = nil
        #expect(NSCursor.current === NSCursor.arrow)
    }

    @Test func outerArcRequiresMoreAndNeverSelectsBeyondVisibleBounds() {
        let model = RadialWindowModel(items: items(10))
        model.updatePointer(point(315, 185), centre: .zero)
        #expect(model.selection == .none && !model.expanded)
        model.updatePointer(point(315, 106), centre: .zero)
        model.updatePointer(point(315, 400), centre: .zero)
        #expect(model.selection == .none && !model.expanded)
        #expect(RadialWindowGeometry.hit(CGVector(dx: 0, dy: -55), ringCount: 8, overflowCount: 0, expanded: false) == .none)
        let gap = RadialWindowGeometry.offset(angle: 22.5, radius: 106)
        #expect(RadialWindowGeometry.hit(CGVector(dx: gap.width, dy: gap.height), ringCount: 8, overflowCount: 0, expanded: false) == .none)
    }

    @Test func pageChangesClearOldSelectionUntilPointerMovesAgain() {
        let model = RadialWindowModel(items: items(14))
        model.updatePointer(point(315, 106), centre: .zero)
        let oldPoint = point(304, 185)
        model.updatePointer(oldPoint, centre: .zero)
        #expect(model.selectedItem != nil)
        model.changePage(1)
        #expect(model.page == 1 && model.pageRange == 13..<14 && model.selection == .none)
        model.updatePointer(oldPoint, centre: .zero)
        #expect(model.selectedItem == nil)
        model.updatePointer(point(315, 185), centre: .zero)
        #expect(model.selectedItem?.id == items(14)[13].id)
        model.changePage(1)
        #expect(model.page == 1)
        model.changePage(-1)
        #expect(model.page == 0)
    }

    @Test func keyboardCanReachEveryOverflowWindowAndReturnToMore() {
        let model = RadialWindowModel(items: items(21))
        var reached = Set<SidebarWindowID>()
        for _ in 0..<8 {
            model.navigate(.next)
            if let item = model.selectedItem { reached.insert(item.id) }
        }
        #expect(model.selectsMore && model.expanded)
        model.navigate(.enter)
        for _ in 7..<21 {
            if let item = model.selectedItem { reached.insert(item.id) }
            model.navigate(.next)
        }
        #expect(reached == Set(items(21).map(\.id)))
        for _ in 0..<14 { model.navigate(.previous) }
        #expect(model.selectsMore)
    }

    @Test func unavailableWindowsKeepTheirSlotsAndCannotBeCommitted() {
        let initial = items(10)
        let model = RadialWindowModel(items: initial)
        model.navigate(.next)
        #expect(model.selectedItem?.id == initial[0].id)
        model.reconcile(availableIDs: Set(initial.dropFirst().map(\.id)))
        #expect(model.items.map(\.id) == initial.map(\.id))
        #expect(!model.items[0].available && model.selectedItem == nil && model.selection == .none)
    }

    @Test func panelClampsOnNegativeCoordinateMonitorWithoutSelectingInitialPointer() throws {
        let available = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let origin = CGPoint(x: -1438, y: -198)
        let frame = try #require(RadialWindowGeometry.panelFrame(at: origin, available: available, overflow: true))
        #expect(available.insetBy(dx: 12, dy: 12).contains(frame))
        let model = RadialWindowModel(items: items(10), pointer: origin)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        model.updatePointer(origin, centre: centre)
        #expect(model.selection == .none)
        #expect(RadialWindowGeometry.panelFrame(at: origin, available: CGRect(x: 0, y: 0, width: 300, height: 300), overflow: true) == nil)
    }

    @Test func loadingAndEmptyCirclesShareTheCursorCentreAndNativeViewSize() throws {
        for pointer in [CGPoint(x: 700, y: 400), CGPoint(x: -1438, y: -198)] {
            let model = RadialWindowModel(pointer: pointer)
            let frame = RadialWindowGeometry.statusFrame(at: pointer)
            let panel = RadialWindowPanel(model: model)
            panel.setFrame(frame, display: true, animate: false)
            let host = try #require(panel.contentView as? NSHostingView<RadialWindowView>)
            defer { panel.close() }
            host.layoutSubtreeIfNeeded()
            #expect(panel.frame.midX == pointer.x && panel.frame.midY == pointer.y)
            #expect(panel.frame.width == model.canvasSize && panel.frame.height == model.canvasSize)
            #expect(host.bounds.size == panel.contentLayoutRect.size)
            let hub = host.convert(CGRect(x: host.bounds.midX, y: host.bounds.midY, width: 0, height: 0), to: nil)
            let hubOnScreen = panel.convertToScreen(hub).origin
            #expect(hubOnScreen == pointer)

            model.load([])
            #expect(RadialWindowGeometry.statusFrame(at: pointer) == frame)
            #expect(model.canvasSize == frame.width)
            #expect(host.bounds.size == panel.contentLayoutRect.size)
        }
    }

    @Test func renderedSectorMatchesClockwiseHitTestingAndNativeCoordinates() throws {
        let model = RadialWindowModel(items: items(8))
        let host = NSHostingView(rootView: RadialWindowView(model: model))
        host.sizingOptions = []
        let size = RadialWindowGeometry.canvas(overflow: false)
        let panel = NSPanel(contentRect: CGRect(x: -700, y: 120, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        for index in 0..<8 {
            let angle = Double(index) * 45
            let offset = RadialWindowGeometry.offset(angle: angle, radius: 106)
            let rendered = CGPoint(x: rect.midX + offset.width, y: rect.midY + offset.height)
            let sector = RadialAnnularSector(start: angle - 22.5, end: angle + 22.5, inner: 62, outer: 150)
            #expect(sector.path(in: rect).contains(rendered))
            let screenPoint = panel.convertToScreen(CGRect(x: rendered.x, y: size - rendered.y, width: 0, height: 0)).origin
            let vector = RadialWindowGeometry.localOffset(pointer: screenPoint, centre: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
            #expect(RadialWindowGeometry.hit(vector, ringCount: 8, overflowCount: 0, expanded: false) == .ring(index))
        }
    }

    @Test func mouseCaptureDrainsReleaseAfterEscapeAndQuickReleaseFinishesOnlyOnce() {
        var session = RadialWindowInputSession()
        let start = session.route(.otherMouseDown, button: 2, canBeginMouse: true)
        let drag = session.route(.otherMouseDragged, button: 2)
        let escape = session.route(.keyDown, key: 53)
        let escapeUp = session.route(.keyUp, key: 53)
        let release = session.route(.otherMouseUp, button: 2)
        let duplicate = session.route(.otherMouseUp, button: 2)
        #expect([start, drag, escape, escapeUp, release, duplicate] == [.beginMouse, .pointer, .cancel, .consume, .consume, .pass])
        #expect(!session.hasOwnedEvents)
        _ = session.route(.otherMouseDown, button: 2, canBeginMouse: true)
        let quick = session.route(.otherMouseUp, button: 2)
        #expect(quick == .finish)
    }

    @Test func disabledModifiedAndUnrelatedButtonsPassThrough() {
        var session = RadialWindowInputSession()
        let routes = [session.route(.otherMouseDown, button: 2),
                      session.route(.otherMouseUp, button: 2),
                      session.route(.otherMouseDown, button: 2, flags: .option, canBeginMouse: true),
                      session.route(.otherMouseDown, button: 3, canBeginMouse: true)]
        #expect(routes == [.pass, .pass, .pass, .pass])
    }

    @Test func keyboardCommitsOnModifierReleaseAndDoesNotReopenOnRepeats() {
        var session = RadialWindowInputSession()
        let started = session.beginKeyboard(modifiers: [.control, .option], key: 49)
        #expect(started)
        let spaceUp = session.route(.keyUp, key: 49)
        let extraModifier = session.route(.flagsChanged, flags: [.control, .option, .shift])
        let repeatStart = session.beginKeyboard(modifiers: [.control, .option], key: 49)
        let release = session.route(.flagsChanged, flags: .control)
        let secondRelease = session.route(.flagsChanged, flags: [])
        #expect(spaceUp == .pass && extraModifier == .pass && !repeatStart)
        #expect(release == .finish && secondRelease == .pass)
    }

    @Test func cancelledKeyboardStillDrainsNavigationKeyUps() {
        var session = RadialWindowInputSession()
        _ = session.beginKeyboard(modifiers: .option, key: 49)
        let arrow = session.route(.keyDown, key: 124)
        session.cancel()
        let repeatKey = session.route(.keyDown, key: 124, repeating: true)
        let release = session.route(.keyUp, key: 124)
        #expect(arrow == .key(124) && repeatKey == .consume && release == .consume)
        #expect(!session.hasOwnedEvents)
    }

    @Test func interruptedCaptureDoesNotSwallowFreshMouseOrKeyPresses() {
        var session = RadialWindowInputSession()
        _ = session.route(.otherMouseDown, button: 2, canBeginMouse: true)
        session.interrupt(modifiers: [])
        // The release occurred while the tap was disabled; this is a new press.
        let newPress = session.route(.otherMouseDown, button: 2, canBeginMouse: true)
        let newRelease = session.route(.otherMouseUp, button: 2)
        #expect(newPress == .beginMouse && newRelease == .finish)

        _ = session.beginKeyboard(modifiers: .option, key: 49)
        _ = session.route(.keyDown, key: 124)
        session.interrupt(modifiers: [])
        let freshArrow = session.route(.keyDown, key: 124)
        let arrowUp = session.route(.keyUp, key: 124)
        #expect(freshArrow == .pass && arrowUp == .pass)
        let restarted = session.beginKeyboard(modifiers: .option, key: 49)
        #expect(restarted)
    }

    @Test func interruptedMiddleCapturePreservesModifiedClicksAndDrainsHeldRelease() {
        var session = RadialWindowInputSession()
        _ = session.route(.otherMouseDown, button: 2, canBeginMouse: true)
        session.interrupt(modifiers: [])
        let heldRelease = session.route(.otherMouseUp, button: 2)
        #expect(heldRelease == .consume)
        _ = session.route(.otherMouseDown, button: 2, canBeginMouse: true)
        session.interrupt(modifiers: [])
        let modifiedDown = session.route(.otherMouseDown, button: 2, flags: .option, canBeginMouse: true)
        let modifiedUp = session.route(.otherMouseUp, button: 2, flags: .option)
        #expect(modifiedDown == .pass && modifiedUp == .pass)
    }

    @Test func interruptedKeyboardRequiresModifierReleaseBeforeReopening() {
        var session = RadialWindowInputSession()
        _ = session.beginKeyboard(modifiers: .option, key: 49)
        session.interrupt(modifiers: .option)
        let repeatedOpen = session.beginKeyboard(modifiers: .option, key: 49)
        #expect(!repeatedOpen)
        _ = session.route(.flagsChanged, flags: [])
        let freshOpen = session.beginKeyboard(modifiers: .option, key: 49)
        #expect(freshOpen)
    }

    @Test func cachedWindowsSkipLoadingAndEmptyMenusIgnoreNavigation() {
        let cached = RadialWindowModel(items: items(3))
        #expect(cached.message == nil && cached.ringCount == 3)
        let empty = RadialWindowModel(items: [])
        empty.navigate(.next)
        empty.navigate(.previous)
        empty.navigate(.enter)
        #expect(empty.message == "No open windows" && empty.selection == .none)
        #expect(RadialWindowModel().message == "Loading windows…")
    }

    @Test func pagingIgnoresMomentumAndRequiresDeliberateTrackpadMovement() {
        var pager = RadialWindowScrollPager()
        let momentum = pager.step(delta: -100, precise: true, momentum: true, time: 0)
        let small = pager.step(delta: -20, precise: true, momentum: false, time: 1)
        let page = pager.step(delta: -20, precise: true, momentum: false, time: 1.1)
        let fast = pager.step(delta: -50, precise: true, momentum: false, time: 1.11)
        let backwards = pager.step(delta: 50, precise: true, momentum: false, time: 2)
        #expect(momentum == nil && small == nil && page == 1 && fast == nil && backwards == -1)
    }

    @Test func focusRequirementPinsIdentityAcrossRestorationAndNeverUsesAppFallback() {
        let element = AXUIElementCreateApplication(20_000)
        let launchDate = Date(timeIntervalSince1970: 1)
        let requirement = SidebarFocusRequirement(element: element, launchDate: launchDate)
        #expect(requirement.matches(element: element, launchDate: launchDate))
        #expect(!requirement.matches(element: AXUIElementCreateApplication(20_001), launchDate: launchDate))
        #expect(!requirement.matches(element: element, launchDate: Date(timeIntervalSince1970: 2)))
        var fallbackCalls = 0
        let accepted = SidebarFocusActivation.activate(target: items(1)[0].id, allowAppFallback: false,
            focusWindow: { _ in false }, activateApp: { _ in fallbackCalls += 1; return true })
        #expect(!accepted && fallbackCalls == 0)
    }

    @Test func middleClickIsOptInAndConflictsAreRejectedInBothDirections() throws {
        let suite = "octopus.radial-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = RadialWindowSettings(defaults: defaults)
        let store = MouseShortcutStore(defaults: defaults)
        #expect(!settings.middleClickEnabled)
        #expect(store.assign(MouseShortcut(button: 2), to: .place) == nil)
        #expect(settings.setMiddleClick(true) != nil)
        #expect(!settings.middleClickEnabled)
        #expect(store.assign(.left, to: .place) == nil)
        #expect(settings.setMiddleClick(true) == nil)
        #expect(RadialWindowSettings(defaults: defaults).middleClickEnabled)
        #expect(store.assign(MouseShortcut(button: 2), to: .hide) != nil)
        #expect(store.assign(MouseShortcut(button: 2, modifiers: .option), to: .hide) == nil)
        #expect(settings.setMiddleClick(false) == nil)
        #expect(store.assign(MouseShortcut(button: 2), to: .hide) == nil)
        #expect(RadialWindowSettings.keyboardError(.init(.space)) != nil)
        #expect(RadialWindowSettings.keyboardError(.init(.tab, modifiers: .control)) != nil)
        #expect(RadialWindowSettings.keyboardError(nil) == nil)
    }

    @Test func catalogueIncludesAllDisplaysDesktopsMinimisedAndHiddenWindows() {
        let app = Application(NSRunningApplication.current)
        app.title = "Example"
        let windows = (1...5).map { number in
            let window = Window(AXUIElementCreateApplication(20_000), app, cachedTitle: "Document")
            window.cgWindowID = UInt32(number)
            return window
        }
        var states: [CGWindowID: SidebarWindowState] = [:]
        for number in 1...5 { states[UInt32(number)] = SidebarWindowState(isMinimized: number == 3,
            canMinimize: true, isOnScreen: number != 4, displayIdentifier: number == 5 ? "other" : "display") }
        let first = SidebarWindowID(pid: 20_000, windowID: 1)
        let second = SidebarWindowID(pid: 20_000, windowID: 2)
        let entry = SidebarEntry(pid: 20_000, application: app, windows: windows,
            preferredID: first, focusedID: first, windowStates: states)
        var anotherDesktopGroup = entry
        anotherDesktopGroup.focusedID = nil
        let result = RadialWindowCatalogue.project(entries: [entry, anotherDesktopGroup],
            recency: [first: 10, second: 5], frontmostPID: 20_000)
        #expect(result.map(\.id) == [second, SidebarWindowID(pid: 20_000, windowID: 3),
            SidebarWindowID(pid: 20_000, windowID: 4), SidebarWindowID(pid: 20_000, windowID: 5), first])
        #expect(result[0].title != result[1].title)
        var hidden = entry
        hidden.isHidden = true
        let hiddenItems = RadialWindowCatalogue.project(entries: [hidden], recency: [:], frontmostPID: nil)
        #expect(Set(hiddenItems.map(\.id)) == Set(result.map(\.id)))
    }

    @Test func closingRetainedSettingsWindowDoesNotKeepRadialInputDisabled() {
        let panel = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 200, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.identifier = PreferencesController.settingsWindowIdentifier
        defer { panel.close() }
        #expect(!RadialWindowSettings.editingBlocksOpening(true, windows: [panel]))
        panel.orderFront(nil)
        #expect(RadialWindowSettings.editingBlocksOpening(true, windows: [panel]))
        #expect(!RadialWindowSettings.editingBlocksOpening(false, windows: [panel]))
        panel.orderOut(nil)
        #expect(!RadialWindowSettings.editingBlocksOpening(true, windows: [panel]))
    }
}
