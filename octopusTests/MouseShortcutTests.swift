import AppKit
import Testing
@testable import octopus

struct MouseShortcutTests {
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

    @MainActor @Test func iconHideFocusesInactiveAppsAndMinimiseUsesTheDisplayedWindow() {
        let app = Application(NSRunningApplication.current)
        let pid = NSRunningApplication.current.processIdentifier
        let window = Window(AXUIElementCreateApplication(pid), app)
        window.cgWindowID = 11
        let id = SidebarWindowID(pid: pid, windowID: 11)
        let entry = SidebarEntry(pid: pid, application: app, windows: [window], preferredID: id)
        #expect(SidebarIconMousePolicy.action(.hide, for: entry, frontmostPID: pid + 1, target: id) == .focus(id))
        #expect(SidebarIconMousePolicy.action(.hide, for: entry, frontmostPID: pid, target: id) == .hide(id))
        #expect(SidebarIconMousePolicy.action(.minimize, for: entry, frontmostPID: pid + 1, target: id) == .minimize(id, requireFocused: false))
        let minimized = SidebarEntry(pid: pid, application: app, windows: [window], preferredID: id,
                                     windowStates: [11: SidebarWindowState(isMinimized: true, canMinimize: true)])
        #expect(SidebarIconMousePolicy.action(.minimize, for: minimized, frontmostPID: pid, target: id) == .focus(id))
        #expect(SidebarIconMousePolicy.action(.place, for: entry, frontmostPID: pid, target: id) == nil)
        let replacement = Window(AXUIElementCreateApplication(pid), app)
        replacement.cgWindowID = 22
        let changed = SidebarEntry(pid: pid, application: app, windows: [window, replacement],
                                   preferredID: SidebarWindowID(pid: pid, windowID: 22))
        #expect(SidebarIconMousePolicy.action(.minimize, for: changed, frontmostPID: pid, target: id) == .minimize(id, requireFocused: false))
        let closed = SidebarEntry(pid: pid, application: app, windows: [replacement], preferredID: changed.preferredID)
        #expect(SidebarIconMousePolicy.action(.minimize, for: closed, frontmostPID: pid, target: id) == nil)
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
