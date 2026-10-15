import AppKit
import Carbon
import KeyboardShortcuts

enum WindowTabShortcut {
    static func direction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard keyCode == UInt16(kVK_Tab) else { return nil }
        let flags = modifiers.intersection([.control, .shift, .option, .command])
        if flags == .control { return 1 }
        if flags == [.control, .shift] { return -1 }
        return nil
    }
}

struct WindowTabShortcutSession {
    enum Route: Equatable { case pass, consume, cycle(SidebarWindowID, Int) }
    private(set) var capturedTab = false

    mutating func route(_ type: CGEventType, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                        repeating: Bool, window: SidebarWindowID?) -> Route {
        guard keyCode == UInt16(kVK_Tab) else { return .pass }
        if type == .keyUp {
            guard capturedTab else { return .pass }
            capturedTab = false
            return .consume
        }
        guard type == .keyDown else { return .pass }
        if capturedTab { return .consume }
        guard !repeating, let direction = WindowTabShortcut.direction(keyCode: keyCode, modifiers: modifiers),
              let window else { return .pass }
        capturedTab = true
        return .cycle(window, direction)
    }

    mutating func cancel() { capturedTab = false }
}

// Unlike a registered global hotkey, this filter leaves Control-Tab available to
// ordinary app windows. No AX reads or focus operations run inside its callback.
@MainActor
final class WindowTabGroupKeyboardMonitor {
    var sourceWindow: () -> SidebarWindowID? = { nil }
    var onSwitch: (SidebarWindowID, Int) -> Void = { _, _ in }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var session = WindowTabShortcutSession()
    private var generation = 0

    func start() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    Unmanaged<WindowTabGroupKeyboardMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, event: event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            session.cancel()
            generation += 1
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Tab) else { return Unmanaged.passUnretained(event) }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        var window: SidebarWindowID?
        if type == .keyDown, !session.capturedTab, !repeating,
           let direction = WindowTabShortcut.direction(keyCode: UInt16(kVK_Tab), modifiers: flags),
           !WindowMonitorShortcuts.conflict(for: .init(.tab, modifiers: direction == 1 ? .control : [.control, .shift]),
                excluding: .init("windowTabGroupCycle")) { window = sourceWindow() }
        switch session.route(type, keyCode: UInt16(kVK_Tab), modifiers: flags, repeating: repeating, window: window) {
        case .pass: return Unmanaged.passUnretained(event)
        case .consume: return nil
        case .cycle(let window, let direction):
            let request = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                self.onSwitch(window, direction)
            }
            return nil
        }
    }

    func stop() {
        generation += 1
        session.cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }
}
