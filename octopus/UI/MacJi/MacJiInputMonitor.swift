//
//  MacJiInputMonitor.swift
//  octopus
//
//  Session event tap that sees every key typed in other apps. It reports
//  key-downs to the controller, which may consume them while the panel is
//  open; the matching key-up is consumed too so apps never see half a press.
//  No AX reads or window work run inside the callback.
//

import AppKit

@MainActor
final class MacJiInputMonitor {
    /// Return true to keep the key from the app.
    var onKeyDown: (_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, _ characters: String) -> Bool = { _, _, _ in false }
    /// The tap was disabled by macOS; any typed-text state is now stale.
    var onInterrupted: () -> Void = {}

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var consumedKeyUps: Set<UInt16> = []

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    Unmanaged<MacJiInputMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, event: event)
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
        EventTapPermissionWatch.shared.tapInstalled(by: self) { [weak self] in self?.stop() }
        return true
    }

    func stop() {
        consumedKeyUps = []
        EventTapPermissionWatch.shared.tapRemoved(by: self)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    ////////////////////
    //// Tap callback
    /// Octopus's own synthetic keys (the emoji insert) pass untouched.
    // Characters come from the event itself, so the active keyboard layout is respected.

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            consumedKeyUps = []
            onInterrupted()
            // An untrusted tap blocks keys system-wide, so re-enable only once trust is confirmed.
            EventTapPermissionWatch.shared.tapDisabled { [weak self] in
                if let tap = self?.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != MacJiTextInserter.syntheticMarker else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            return consumedKeyUps.remove(keyCode) == nil ? Unmanaged.passUnretained(event) : nil
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        guard onKeyDown(keyCode, modifiers, Self.characters(of: event)) else { return Unmanaged.passUnretained(event) }
        consumedKeyUps.insert(keyCode)
        return nil
    }

    private static func characters(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: min(length, buffer.count))
    }

    //// Unhandled keys always pass through, so a slow handler never eats typing.
    //////////////////
}
