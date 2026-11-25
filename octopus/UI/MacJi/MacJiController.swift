//
//  MacJiController.swift
//  octopus
//
//  MacJi: type the trigger (default "::") and a term in any app, e.g. "::roc",
//  to open an emoji panel under the caret.
//  Return replaces "::roc" with the selection · Shift-Return copies it ·
//  Esc closes · Space or punctuation closes as you keep typing.
//

import AppKit

@MainActor
final class MacJiController {
    /// How long the "Copied" badge shows before the panel closes itself.
    private static let copyCloseDelay: TimeInterval = 0.9

    private let monitor = MacJiInputMonitor()
    private let model = MacJiModel()
    private let secureInputNotifier = MacJiSecureInputNotifier()
    private lazy var panel = MacJiPanel(rootView: MacJiView(model: model) { [weak self] in self?.insert($0) })
    private var tracker = MacJiTriggerTracker(trigger: MacJiSettings.defaultTrigger)
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pointerMonitor: Any?
    private var copyClose: DispatchWorkItem?

    func start() {
        MacJiSettings.registerDefaults()
        monitor.onKeyDown = { [weak self] in self?.handleKeyDown($0, $1, $2) ?? false }
        monitor.onInterrupted = { [weak self] in self?.endSession() }
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        })
        // Switching apps moves the caret; it is also a cheap moment to retry the
        // tap after Accessibility was granted, and to report a background app
        // whose Secure Input hides every key from the tap.
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.endSession()
                self?.applySettings()
                if MacJiSettings.isEnabled { self?.secureInputNotifier.check(frontmostPID: app?.processIdentifier) }
            }
        })
        applySettings()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        stopListening()
    }

    ////////////////////
    //// Settings
    /// Follows Preferences > General: the on/off toggle and the trigger text.

    private func applySettings() {
        let trigger = MacJiSettings.trigger
        if tracker.trigger != trigger {
            tracker.trigger = trigger
            endSession()
        }
        if MacJiSettings.isEnabled { startListening() } else { stopListening() }
    }

    private func startListening() {
        guard !monitor.isRunning, monitor.start() else { return }
        // Any click can move the caret, so the typed buffer no longer matches the text.
        // Global monitors never see clicks in Octopus's own panel.
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.endSession() }
        }
    }

    private func stopListening() {
        monitor.stop()
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        endSession()
    }

    //// The tap only exists while MacJi is on and Accessibility is granted.
    //////////////////

    ////////////////////
    //// Key handling (runs inside the event tap)
    /// While a term is open, panel keys are consumed and handled on the next
    /// main-queue turn; every other key passes through and updates the buffer.
    // The buffer is updated synchronously so fast typing never races the panel.

    private func handleKeyDown(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, _ characters: String) -> Bool {
        if tracker.query != nil, let action = MacJiKeyAction(keyCode: keyCode, modifiers: modifiers),
           action == .close || !model.results.isEmpty {
            if case .move(let key) = action {
                DispatchQueue.main.async { [weak self] in self?.model.moveSelection(key) }
            } else {
                let length = tracker.replacementLength
                tracker.reset()
                DispatchQueue.main.async { [weak self] in self?.perform(action, replacing: length) }
            }
            return true
        }
        tracker.apply(MacJiTypedKey(keyCode: keyCode, modifiers: modifiers, characters: characters))
        let query = tracker.query
        DispatchQueue.main.async { [weak self] in self?.refresh(query) }
        return false
    }

    //// Return with no results passes through, so MacJi never swallows a line break for nothing.
    //////////////////

    private func perform(_ action: MacJiKeyAction, replacing length: Int) {
        switch action {
        case .insert:
            guard let emoji = model.selectedEmoji ?? model.results.first else { hidePanel(); return }
            replace(length, with: emoji)
        case .copy:
            guard let emoji = model.selectedEmoji ?? model.results.first, model.copy(emoji) else {
                NSSound.beep()
                hidePanel()
                return
            }
            let close = DispatchWorkItem { [weak self] in self?.hidePanel() }
            copyClose = close
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.copyCloseDelay, execute: close)
        case .close, .move:
            hidePanel()
        }
    }

    /// Pointer click on a result.
    private func insert(_ emoji: Emoji) {
        let length = tracker.replacementLength
        guard length > 0 else { hidePanel(); return }
        tracker.reset()
        replace(length, with: emoji)
    }

    private func replace(_ length: Int, with emoji: Emoji) {
        hidePanel()
        MacJiTextInserter.replace(characterCount: length, with: emoji.emoji)
    }

    private func endSession() {
        tracker.reset()
        hidePanel()
    }

    ////////////////////
    //// Panel visibility
    /// The caret is looked up once per open; the panel stays put while typing.

    private func refresh(_ query: String?) {
        guard let query else {
            if copyClose == nil { hidePanel() }
            return
        }
        copyClose?.cancel()
        copyClose = nil
        model.update(query: query, trigger: tracker.trigger)
        guard !panel.isVisible else { return }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let frame = MacJiPanelPlacement.frame(card: MacJiView.cardSize, caret: MacJiCaretLocator.caretRect(),
                                              pointer: NSEvent.mouseLocation, visibleFrames: visibleFrames)
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        copyClose?.cancel()
        copyClose = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.reset()
    }

    //// A pending copy-close keeps the badge visible until its timer fires.
    //////////////////
}
