import AppKit
import Testing
@testable import octopus

struct MouseShortcutTests {
    @MainActor @Test func cornerChordPersistsCustomDisableAndResetIndependentlyOfDragBinding() throws {
        try withStore { store, defaults in
            let binding = MouseShortcut(button: 2, modifiers: .command)
            #expect(store.assign(binding, to: .place) == nil)
            #expect(store.cornerSnapModifiers == [.control, .option, .shift])
            store.setCornerSnapModifiers([.option, .shift, .capsLock])
            #expect(MouseShortcutStore(defaults: defaults).cornerSnapModifiers == [.option, .shift])
            store.setCornerSnapModifiers([])
            #expect(SidebarCornerSnapShortcut.read(in: defaults).isEmpty)
            #expect(!SidebarCornerSnapShortcut.matches([], required: []))
            store.resetCornerSnapModifiers()
            #expect(store.cornerSnapModifiers == SidebarCornerSnapShortcut.defaultModifiers)
            #expect(store.bindings.place == binding)
            defaults.set("invalid", forKey: SidebarCornerSnapShortcut.key)
            #expect(SidebarCornerSnapShortcut.read(in: defaults) == SidebarCornerSnapShortcut.defaultModifiers)
            store.resetAll()
            #expect(store.cornerSnapModifiers == SidebarCornerSnapShortcut.defaultModifiers)
        }
    }

    @Test func cornerChordAugmentsOnlyTheConfiguredDragButtonAndModifiers() {
        let chord = SidebarCornerSnapShortcut.defaultModifiers
        let binding = MouseShortcut(button: 2, modifiers: .command)
        func allowed(_ button: Int, _ flags: NSEvent.ModifierFlags, required: NSEvent.ModifierFlags = chord) -> Bool {
            SidebarCornerSnapShortcut.allowsDrag(MouseShortcut(button: button, modifiers: flags), binding: binding, cornerModifiers: required)
        }
        #expect(allowed(2, .command))
        #expect(allowed(2, chord.union(.command)))
        #expect(!allowed(0, chord.union(.command)))
        #expect(!allowed(2, chord)) // The drag's Command modifier is still required.
        #expect(!allowed(2, chord.union(.command), required: []))
        #expect(!SidebarCornerSnapShortcut.allowsDrag(.left, binding: nil, cornerModifiers: chord))
        #expect(SidebarCornerSnapShortcut.matches(chord.union(.command), required: chord))
        #expect(!SidebarCornerSnapShortcut.matches([.control, .option], required: chord))
    }

    @MainActor @Test func preheldCornerChordStartsNativeDragAndSuppressesClick() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.dragShortcut = MouseShortcut(button: 1, modifiers: .command)
        view.cornerModifiersProvider = { [.control, .option, .shift] }
        var drags = 0, clicks = 0
        view.onDrag = { _, _ in drags += 1 }
        view.onMouseClick = { _ in clicks += 1 }
        let flags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        view.rightMouseDown(with: try event(.rightMouseDown, modifiers: flags))
        view.rightMouseDragged(with: try event(.rightMouseDragged, point: CGPoint(x: 30, y: 10), modifiers: flags))
        view.rightMouseUp(with: try event(.rightMouseUp, modifiers: flags))
        #expect(drags == 1 && clicks == 0)
    }

    @Test func sidebarScrollGestureStaysLatchedUntilRequiredModifiersAreReleased() {
        var session = SidebarPositionScrollSession()
        let began = session.begin(.control)
        #expect(began)
        // Routing no longer depends on the pointer or the sidebar's moving bounds.
        let routes = [
            session.route(.scrollWheel, flags: .control),
            session.route(.scrollWheel, flags: [.control, .shift]),
            session.route(.flagsChanged, flags: .control),
            session.route(.flagsChanged, flags: []),
            session.route(.scrollWheel, flags: .control)
        ]
        #expect(routes == [.consume, .consume, .pass, .end, .pass])
        let combinationBegan = session.begin([.option, .shift])
        #expect(combinationBegan)
        let combinationRoutes = [
            session.route(.scrollWheel, flags: [.option, .shift]),
            session.route(.flagsChanged, flags: .option)
        ]
        #expect(combinationRoutes == [.consume, .end])
    }

    @Test func sidebarScrollCaptureDisablesSafelyAndCannotStartWithoutModifiers() {
        var session = SidebarPositionScrollSession()
        let disabled = session.begin([])
        #expect(!disabled)
        let inactiveRoute = session.route(.scrollWheel, flags: .control)
        #expect(inactiveRoute == .pass)
        let began = session.begin(.control)
        #expect(began)
        let timeoutRoutes = [
            session.route(.tapDisabledByTimeout, flags: .control),
            session.route(.scrollWheel, flags: .control)
        ]
        #expect(timeoutRoutes == [.end, .pass])
        _ = session.begin(.control)
        session.end()
        let endedRoute = session.route(.scrollWheel, flags: .control)
        #expect(endedRoute == .pass)
    }

    @MainActor @Test func sidebarScrollModifiersPersistDisableAndResetWithoutChangingClicks() throws {
        try withStore { store, defaults in
            let clicks = store.bindings
            #expect(store.positionScrollModifiers == .control)
            store.setPositionScrollModifiers([.option, .shift, .capsLock])
            #expect(SidebarPositionScrollShortcut.read(in: defaults) == [.option, .shift])
            #expect(SidebarPositionScrollShortcut.matches([.option, .shift, .capsLock], required: [.option, .shift]))
            #expect(!SidebarPositionScrollShortcut.matches([.control, .shift], required: .control))
            store.setPositionScrollModifiers([])
            #expect(SidebarPositionScrollShortcut.read(in: defaults).isEmpty)
            #expect(!SidebarPositionScrollShortcut.matches([], required: []))
            #expect(store.bindings == clicks)
            store.resetAll()
            #expect(store.positionScrollModifiers == .control)
            #expect(SidebarPositionScrollShortcut.read(in: defaults) == .control)
            defaults.set("invalid", forKey: SidebarPositionScrollShortcut.key)
            #expect(SidebarPositionScrollShortcut.read(in: defaults) == .control)
        }
    }

    @MainActor @Test func defaultsUseDistinctClicksAndShareLeftClickWithDragging() throws {
        try withStore { store, _ in
            #expect(store.bindings.hide == .right)
            #expect(store.bindings.minimize == .left)
            #expect(store.bindings.place == .left)
            #expect(store.bindings.clickAction(for: .left) == .minimize)
            #expect(store.bindings.clickAction(for: .right) == .hide)
        }
    }

    @MainActor @Test func duplicateHideAndMinimiseAssignmentsAreRejectedWithoutChangingAnything() throws {
        try withStore { store, defaults in
            #expect(store.assign(.left, to: .hide) != nil)
            #expect(store.assign(.right, to: .minimize) != nil)
            #expect(store.bindings.hide == .right && store.bindings.minimize == .left)
            #expect(defaults.string(forKey: MouseShortcutAction.hide.key) == nil)
            #expect(store.assign(.left, to: .place) == nil)
            #expect(store.bindings.place == .left)
        }
    }

    @MainActor @Test func clearedBindingsStayDisabledAfterReloadAndAllowReassignment() throws {
        try withStore { store, defaults in
            #expect(store.assign(nil, to: .hide) == nil)
            #expect(store.assign(.left, to: .minimize) == nil)
            let reloaded = MouseShortcutBindings(defaults: defaults)
            #expect(reloaded.hide == nil)
            #expect(reloaded.minimize == .left)
            #expect(store.assign(nil, to: .place) == nil)
            #expect(MouseShortcutBindings(defaults: defaults).place == nil)
        }
    }

    @MainActor @Test func modifierCombosAreDistinctAndAdditionalMouseButtonsPersist() throws {
        try withStore { store, defaults in
            let modifiedLeft = MouseShortcut(button: 0, modifiers: [.control, .capsLock])
            #expect(store.assign(modifiedLeft, to: .minimize) == nil)
            #expect(store.bindings.hide == .right)
            #expect(modifiedLeft.modifiers == .control)
            let sideButton = MouseShortcut(button: 4, modifiers: [.option, .shift])
            #expect(store.assign(sideButton, to: .place) == nil)
            #expect(MouseShortcutBindings(defaults: defaults).place == sideButton)
            #expect(store.assign(MouseShortcut(button: -1), to: .hide) != nil)
        }
    }

    @MainActor @Test func resetRestoresEachDefaultAndRejectsConflictsWithoutChangingOtherRows() throws {
        try withStore { store, defaults in
            #expect(store.assign(nil, to: .hide) == nil)
            #expect(store.assign(.right, to: .minimize) == nil)
            #expect(store.reset(.hide) != nil)
            #expect(store.bindings.hide == nil && store.bindings.minimize == .right)
            #expect(store.reset(.minimize) == nil)
            #expect(store.reset(.hide) == nil)
            #expect(store.assign(nil, to: .place) == nil)
            #expect(store.reset(.place) == nil)
            let reloaded = MouseShortcutBindings(defaults: defaults)
            #expect(reloaded.hide == .right && reloaded.minimize == .left && reloaded.place == .left)
        }
    }

    @MainActor @Test func invalidOrDuplicateStoredValuesCannotTriggerTwoClickActions() throws {
        try withStore { _, defaults in
            defaults.set(MouseShortcut.right.saved, forKey: MouseShortcutAction.minimize.key)
            let duplicate = MouseShortcutBindings(defaults: defaults)
            #expect(duplicate.hide == .right && duplicate.minimize == nil)
            defaults.set("broken", forKey: MouseShortcutAction.minimize.key)
            #expect(MouseShortcutBindings(defaults: defaults).minimize == .left)
            #expect(MouseShortcut(saved: "33:0") == nil)
            #expect(MouseShortcut(saved: "1:1") == nil)
        }
    }

    @MainActor @Test func resetAllRestoresSwappedAndDisabledBindingsTogether() throws {
        try withStore { store, defaults in
            #expect(store.assign(nil, to: .hide) == nil)
            #expect(store.assign(.right, to: .minimize) == nil)
            #expect(store.assign(.left, to: .hide) == nil)
            #expect(store.assign(nil, to: .place) == nil)
            store.resetAll()
            #expect(store.bindings.hide == .right && store.bindings.minimize == .left && store.bindings.place == .left)
            #expect(MouseShortcutBindings(defaults: defaults) == store.bindings)
        }
    }

    @MainActor @Test func rightClickAndRightDragAreExclusiveAndUseTheInitiatingEvent() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.dragShortcut = .right
        var clicks = 0
        var drags = 0
        view.onMouseClick = { shortcut in #expect(shortcut == .right); clicks += 1 }
        view.onDrag = { _, event in
            #expect(event.type == .rightMouseDown && event.buttonNumber == 1)
            drags += 1
        }
        view.rightMouseDown(with: try event(.rightMouseDown))
        view.rightMouseUp(with: try event(.rightMouseUp))
        #expect(clicks == 1 && drags == 0)
        view.rightMouseDown(with: try event(.rightMouseDown, time: 2))
        view.rightMouseDragged(with: try event(.rightMouseDragged, point: CGPoint(x: 30, y: 10), time: 2))
        view.rightMouseUp(with: try event(.rightMouseUp, point: CGPoint(x: 30, y: 10), time: 2))
        #expect(clicks == 1 && drags == 1)
    }

    @MainActor @Test func mismatchedDragsCancelClicksAndBindingsAreCapturedAtPress() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.dragShortcut = .right
        var clicks = 0
        var drags = 0
        view.onMouseClick = { _ in clicks += 1 }
        view.onDrag = { _, _ in drags += 1 }
        view.mouseDown(with: try event(.leftMouseDown))
        view.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: 30, y: 10)))
        view.mouseUp(with: try event(.leftMouseUp, point: CGPoint(x: 30, y: 10)))
        #expect(clicks == 0 && drags == 0)
        view.rightMouseDown(with: try event(.rightMouseDown, time: 2))
        view.dragShortcut = .left
        view.rightMouseDragged(with: try event(.rightMouseDragged, point: CGPoint(x: 30, y: 10), time: 2))
        #expect(drags == 1)
    }

    @MainActor @Test func sideButtonDragsUseTheirRecordedButtonAndModifiers() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.dragShortcut = MouseShortcut(button: 4, modifiers: .option)
        var drags = 0
        view.onDrag = { _, event in #expect(event.buttonNumber == 4); drags += 1 }
        view.otherMouseDown(with: try event(.otherMouseDown, modifiers: .option, buttonNumber: 4))
        view.otherMouseDragged(with: try event(.otherMouseDragged, point: CGPoint(x: 30, y: 10), modifiers: .option, buttonNumber: 4))
        view.otherMouseUp(with: try event(.otherMouseUp, point: CGPoint(x: 30, y: 10), modifiers: .option, buttonNumber: 4))
        #expect(drags == 1)
    }

    @MainActor @Test func recorderCapturesRightClickWithModifiersAndEscapeCancels() throws {
        let button = MouseShortcutRecorder.RecorderButton()
        button.isRecording = true
        var recorded: MouseShortcut?
        var cancelled = false
        button.onRecord = { recorded = $0 }
        button.onCancel = { cancelled = true }
        button.rightMouseDown(with: try event(.rightMouseDown, modifiers: [.command, .shift]))
        #expect(recorded == MouseShortcut(button: 1, modifiers: [.command, .shift]))
        #expect(!button.isRecording)
        button.isRecording = true
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        button.keyDown(with: escape)
        #expect(cancelled)
    }

    @MainActor @Test func recordingLeftClickDoesNotRearmTheRecorderOnRelease() throws {
        let button = MouseShortcutRecorder.RecorderButton()
        button.isRecording = true
        button.target = button
        button.action = #selector(MouseShortcutRecorder.RecorderButton.beginRecording)
        var recorded: MouseShortcut?
        var starts = 0
        button.onRecord = { recorded = $0 }
        button.onBegin = { starts += 1 }
        button.mouseDown(with: try event(.leftMouseDown))
        button.mouseUp(with: try event(.leftMouseUp))
        #expect(recorded == .left && !button.isRecording && starts == 0)
    }

    @MainActor @Test func iconHideFocusesInactiveAppsAndMinimiseOnlyActsOnTheFrontFocusedWindow() {
        let app = Application(NSRunningApplication.current)
        let pid = NSRunningApplication.current.processIdentifier
        let window = Window(AXUIElementCreateApplication(pid), app)
        window.cgWindowID = 11
        let id = SidebarWindowID(pid: pid, windowID: 11)
        let entry = SidebarEntry(pid: pid, application: app, windows: [window], preferredID: id, focusedID: id)
        #expect(SidebarIconMousePolicy.action(.hide, for: entry, frontmostPID: pid + 1, target: id) == .focus(id))
        #expect(SidebarIconMousePolicy.action(.hide, for: entry, frontmostPID: pid, target: id) == .hide(id))
        // A visible but covered app (another app is frontmost) must come forward, never minimise.
        #expect(SidebarIconMousePolicy.action(.minimize, for: entry, frontmostPID: pid + 1, target: id) == .focus(id))
        #expect(SidebarIconMousePolicy.action(.minimize, for: entry, frontmostPID: nil, target: id) == .focus(id))
        #expect(SidebarIconMousePolicy.action(.minimize, for: entry, frontmostPID: pid, target: id) == .minimize(id, requireFocused: true))
        let minimized = SidebarEntry(pid: pid, application: app, windows: [window], preferredID: id,
                                     windowStates: [11: SidebarWindowState(isMinimized: true, canMinimize: true)])
        #expect(SidebarIconMousePolicy.action(.minimize, for: minimized, frontmostPID: pid, target: id) == .focus(id))
        #expect(SidebarIconMousePolicy.action(.place, for: entry, frontmostPID: pid, target: id) == nil)
        let replacement = Window(AXUIElementCreateApplication(pid), app)
        replacement.cgWindowID = 22
        let changed = SidebarEntry(pid: pid, application: app, windows: [window, replacement],
                                   preferredID: SidebarWindowID(pid: pid, windowID: 22))
        // A non-focused window of the frontmost app may be covered by its sibling; raise it.
        #expect(SidebarIconMousePolicy.action(.minimize, for: changed, frontmostPID: pid, target: id) == .focus(id))
        let closed = SidebarEntry(pid: pid, application: app, windows: [replacement], preferredID: changed.preferredID)
        #expect(SidebarIconMousePolicy.action(.minimize, for: closed, frontmostPID: pid, target: id) == nil)
    }

    @MainActor @Test func defaultLeftClickOnWindowlessAppReachesAppActivation() throws {
        try withStore { store, _ in
            let app = Application(NSRunningApplication.current)
            let pid = NSRunningApplication.current.processIdentifier
            let entry = SidebarEntry(pid: pid, application: app, windows: [], preferredID: nil)
            #expect(store.bindings.clickAction(for: .left) == .minimize)
            for frontmost in [Optional(pid), nil] {
                let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
                view.dragShortcut = store.bindings.place
                var actions: [SidebarWindowAction] = []
                view.onMouseClick = { shortcut in
                    guard let mapping = store.bindings.clickAction(for: shortcut),
                          let action = SidebarIconMousePolicy.action(mapping, for: entry,
                              frontmostPID: frontmost, target: SidebarIconDragPolicy.target(for: entry)) else { return }
                    actions.append(action)
                }
                view.mouseDown(with: try event(.leftMouseDown))
                view.mouseUp(with: try event(.leftMouseUp, time: 1.01))
                #expect(actions == [.activateApp(pid)])
            }
        }
    }

    @MainActor @Test func windowlessClickDoesNotReopenAStaleTargetOrAnotherWindowGroup() {
        let app = Application(NSRunningApplication.current)
        let pid = NSRunningApplication.current.processIdentifier
        var entry = SidebarEntry(pid: pid, application: app, windows: [], preferredID: nil)
        let stale = SidebarWindowID(pid: pid, windowID: 11)
        #expect(SidebarIconMousePolicy.action(.minimize, for: entry, frontmostPID: pid, target: stale) == nil)
        entry.hasOtherWindows = true
        #expect(SidebarIconMousePolicy.action(.minimize, for: entry, frontmostPID: pid, target: nil) == nil)
        let staleEntry = SidebarEntry(pid: pid, application: app, windows: [], preferredID: stale)
        #expect(SidebarIconMousePolicy.action(.minimize, for: staleEntry, frontmostPID: pid, target: nil) == nil)
    }

    @MainActor @Test func remoteWindowClickFocusesBeforeMinimizingEvenWhenItsAppIsAlreadyActive() {
        let app = Application(NSRunningApplication.current)
        let pid = NSRunningApplication.current.processIdentifier
        let window = Window(AXUIElementCreateApplication(pid), app)
        window.cgWindowID = 11
        let id = SidebarWindowID(pid: pid, windowID: 11)
        var entry = SidebarEntry(pid: pid, application: app, windows: [window], preferredID: id,
            focusedID: id, windowStates: [11: SidebarWindowState(isMinimized: false, canMinimize: true, isOnScreen: false)])
        for frontmost in [pid, pid + 1] {
            for action in [MouseShortcutAction.minimize, .hide] {
                #expect(SidebarIconMousePolicy.action(action, for: entry, frontmostPID: frontmost, target: id) == .focus(id))
            }
        }
        // After arriving, the same shortcut can minimise; a minimised window restores.
        entry.windowStates[11]?.isOnScreen = true
        #expect(SidebarIconMousePolicy.action(.minimize, for: entry, frontmostPID: pid, target: id)
                == .minimize(id, requireFocused: true))
        entry.windowStates[11] = SidebarWindowState(isMinimized: true, canMinimize: true, isOnScreen: false)
        #expect(SidebarIconMousePolicy.action(.minimize, for: entry, frontmostPID: pid, target: id) == .focus(id))
    }

    @MainActor private func withStore(_ body: (MouseShortcutStore, UserDefaults) throws -> Void) throws {
        let name = "MouseShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(MouseShortcutStore(defaults: defaults), defaults)
    }

    @MainActor private func event(_ type: NSEvent.EventType, point: CGPoint = CGPoint(x: 10, y: 10),
                                  time: TimeInterval = 1, modifiers: NSEvent.ModifierFlags = [],
                                  buttonNumber: Int? = nil) throws -> NSEvent {
        let right = [.rightMouseDown, .rightMouseDragged, .rightMouseUp].contains(type)
        let other = [.otherMouseDown, .otherMouseDragged, .otherMouseUp].contains(type)
        let button: CGMouseButton = right ? .right : other ? .center : .left
        let nativeType = try #require(CGEventType(rawValue: UInt32(type.rawValue)))
        let position = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: nativeType, mouseCursorPosition: position, mouseButton: button))
        cg.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        cg.timestamp = UInt64(time * 1_000_000_000)
        cg.setIntegerValueField(.mouseEventClickState, value: 1)
        if let buttonNumber { cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(buttonNumber)) }
        let result = try #require(NSEvent(cgEvent: cg))
        #expect(result.locationInWindow == point)
        return result
    }
}
