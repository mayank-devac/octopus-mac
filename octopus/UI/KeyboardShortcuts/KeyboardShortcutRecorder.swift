import AppKit
import SwiftUI
import KeyboardShortcuts

// A button avoids AppKit's field editor and its text caret.
struct KeyboardShortcutRecorder: NSViewRepresentable {
    let name: KeyboardShortcuts.Name
    var onRecord: (KeyboardShortcuts.Shortcut?) -> String?
    var onError: (String?) -> Void

    func makeNSView(context: Context) -> Control {
        Control(name: name, onRecord: onRecord, onError: onError)
    }

    func updateNSView(_ control: Control, context: Context) {
        control.onRecord = onRecord
        control.onError = onError
        control.refresh()
    }

    static func dismantleNSView(_ control: Control, coordinator: ()) {
        control.finishRecording()
    }

    final class Control: NSStackView {
        // Recording must also work when macOS keyboard navigation is disabled.
        private final class RecordButton: NSButton {
            override var acceptsFirstResponder: Bool { true }
        }

        private static weak var activeRecorder: Control?
        private let name: KeyboardShortcuts.Name
        private let recordButton = RecordButton(title: "Record", target: nil, action: nil)
        private let clearButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear shortcut")!, target: nil, action: nil)
        private final class Session {
            var eventMonitor: Any?
            var tap: CFMachPort?
            var source: CFRunLoopSource?
            var focusObserver: NSObjectProtocol?
            var pendingShortcut: KeyboardShortcuts.Shortcut?
            private let previousEnabled = KeyboardShortcuts.isEnabled

            init() { KeyboardShortcuts.isEnabled = false }

            deinit {
                if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
                if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
                if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
                if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
                if let tap { CFMachPortInvalidate(tap) }
                KeyboardShortcuts.isEnabled = previousEnabled
            }
        }

        private var session: Session?
        var onRecord: (KeyboardShortcuts.Shortcut?) -> String?
        var onError: (String?) -> Void

        init(name: KeyboardShortcuts.Name, onRecord: @escaping (KeyboardShortcuts.Shortcut?) -> String?,
             onError: @escaping (String?) -> Void) {
            self.name = name
            self.onRecord = onRecord
            self.onError = onError
            super.init(frame: .zero)
            orientation = .horizontal
            spacing = 4
            recordButton.bezelStyle = .rounded
            recordButton.target = self
            recordButton.action = #selector(beginRecording)
            recordButton.toolTip = "Click to record a key combination; release the key to save. Escape cancels."
            clearButton.isBordered = false
            clearButton.target = self
            clearButton.action = #selector(clearShortcut)
            clearButton.toolTip = "Remove this shortcut"
            addArrangedSubview(recordButton)
            addArrangedSubview(clearButton)
            recordButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
            clearButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
            refresh()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func beginRecording() {
            if session != nil { finishRecording(); return }
            Self.activeRecorder?.finishRecording()
            guard let window, window.makeFirstResponder(recordButton) else { return }
            Self.activeRecorder = self
            onError(nil)
            let session = Session()
            self.session = session
            installRecordingTap(session)
            session.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.type != .keyDown && event.type != .keyUp {
                    self.finishRecording()
                    return event
                }
                // Key events can have no associated window. The active settings
                // window owns recording; a nil event.window must not cancel it.
                guard self.window?.isKeyWindow == true else {
                    self.cancelForLostFocus()
                    return event
                }
                // The event tap owns key capture when installed; the local
                // monitor remains responsible for outside clicks and fallback.
                if self.session?.tap != nil { return event }
                return self.capture(event)
            }
            session.focusObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.cancelForLostFocus() }
            refresh()
        }

        private func installRecordingTap(_ session: Session) {
            guard AXIsProcessTrusted() else { return }
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    return MainActor.assumeIsolated {
                        let control = Unmanaged<Control>.fromOpaque(context).takeUnretainedValue()
                        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                            control.finishRecording()
                            control.onError("Recording was interrupted. Click Record to try again.")
                            return Unmanaged.passUnretained(event)
                        }
                        guard control.window?.isKeyWindow == true else {
                            control.cancelForLostFocus()
                            return Unmanaged.passUnretained(event)
                        }
                        guard let keyEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
                        return control.capture(keyEvent) == nil ? nil : Unmanaged.passUnretained(event)
                    }
                }, userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else { return }
            guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
                CFMachPortInvalidate(tap)
                return
            }
            session.tap = tap
            session.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        private func cancelForLostFocus() {
            guard session != nil else { return }
            finishRecording()
            onError("Recording cancelled because Settings lost focus; macOS may be using that shortcut.")
        }

        private func capture(_ event: NSEvent) -> NSEvent? {
            guard let session else { return event }
            if event.type == .keyUp {
                if let shortcut = session.pendingShortcut, shortcut.carbonKeyCode == Int(event.keyCode) {
                    finishRecording()
                    // A confirmation alert must open after the event tap consumes the release.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.onError(self.onRecord(shortcut))
                        self.refresh()
                    }
                }
                return nil
            }
            guard !event.isARepeat else { return nil }
            if event.keyCode == 53 { finishRecording(); return nil }
            guard session.pendingShortcut == nil, let shortcut = KeyboardShortcuts.Shortcut(event: event) else { return nil }
            let modifiers = event.modifierFlags.intersection(MouseShortcut.supportedModifiers)
            let isFunctionKey = event.specialKey.map {
                (NSEvent.SpecialKey.f1.rawValue...NSEvent.SpecialKey.f35.rawValue).contains($0.rawValue)
            } ?? false
            guard !modifiers.subtracting(.shift).isEmpty || isFunctionKey else {
                onError("Use Control, Option or Command with a key.")
                return nil
            }
            if let error = shortcutError(shortcut, event: event) {
                onError(error)
                return nil
            }
            onError(nil)
            session.pendingShortcut = shortcut
            refresh()
            return nil
        }

        private func shortcutError(_ shortcut: KeyboardShortcuts.Shortcut, event: NSEvent) -> String? {
            if let menu = NSApp.mainMenu, menuContainsShortcut(menu, event: event) {
                return "This shortcut is used by an Octopus menu command. Choose another."
            }
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            if osVersion.majorVersion == 15, osVersion.minorVersion <= 1,
               ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
               shortcut.modifiers.contains(.option),
               shortcut.modifiers.intersection([.command, .control]).isEmpty {
                return "Add Control or Command to this shortcut on this macOS version."
            }
            return nil
        }

        private func menuContainsShortcut(_ menu: NSMenu, event: NSEvent) -> Bool {
            for item in menu.items {
                if let submenu = item.submenu, menuContainsShortcut(submenu, event: event) { return true }
                guard !item.keyEquivalent.isEmpty else { continue }
                var modifiers = item.keyEquivalentModifierMask.intersection(MouseShortcut.supportedModifiers)
                if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
                if item.keyEquivalent.lowercased() == event.charactersIgnoringModifiers?.lowercased(),
                   modifiers == event.modifierFlags.intersection(MouseShortcut.supportedModifiers) { return true }
            }
            return false
        }

        @objc private func clearShortcut() {
            finishRecording()
            onError(onRecord(nil))
            refresh()
        }

        func finishRecording() {
            session = nil
            if Self.activeRecorder === self { Self.activeRecorder = nil }
            refresh()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { finishRecording() }
            super.viewWillMove(toWindow: newWindow)
        }

        func refresh() {
            let saved = KeyboardShortcuts.getShortcut(for: name)
            if let session {
                recordButton.title = session.pendingShortcut.map { "\($0)" } ?? "Press shortcut…"
                recordButton.setAccessibilityLabel("Recording keyboard shortcut. Escape cancels.")
            } else {
                recordButton.title = saved.map { "\($0)" } ?? "Record"
                recordButton.setAccessibilityLabel(saved.map { "Record keyboard shortcut, currently \($0)" } ?? "Record keyboard shortcut")
            }
            clearButton.isEnabled = saved != nil
        }
    }
}

