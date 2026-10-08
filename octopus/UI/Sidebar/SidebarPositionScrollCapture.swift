import AppKit

struct SidebarPositionScrollSession {
    enum Route { case pass, consume, end }
    private(set) var modifiers: NSEvent.ModifierFlags?

    mutating func begin(_ required: NSEvent.ModifierFlags) -> Bool {
        let supported = required.intersection(MouseShortcut.supportedModifiers)
        guard !supported.isEmpty else { return false }
        modifiers = supported
        return true
    }

    mutating func route(_ type: CGEventType, flags: NSEvent.ModifierFlags) -> Route {
        guard let modifiers else { return .pass }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput || !flags.isSuperset(of: modifiers) {
            self.modifiers = nil
            return .end
        }
        return type == .scrollWheel ? .consume : .pass
    }

    mutating func end() { modifiers = nil }
}

// Install an active filter only during a sidebar movement gesture. Events that
// move the sidebar never reach the app beneath the pointer.
@MainActor
final class SidebarPositionScrollCapture {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var session = SidebarPositionScrollSession()
    private var generation = 0
    private var onScroll: ((NSEvent) -> Void)?
    private var onEnd: (() -> Void)?
    var isActive: Bool { tap != nil && session.modifiers != nil }
    var modifiers: NSEvent.ModifierFlags? { session.modifiers }

    func start(modifiers: NSEvent.ModifierFlags, onScroll: @escaping (NSEvent) -> Void,
               onEnd: @escaping () -> Void) -> Bool {
        stop()
        guard AXIsProcessTrusted(), session.begin(modifiers) else { return false }
        let mask = (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    Unmanaged<SidebarPositionScrollCapture>.fromOpaque(context).takeUnretainedValue().handle(type, event: event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            session.end()
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            session.end()
            return false
        }
        self.tap = tap
        self.source = source
        self.onScroll = onScroll
        self.onEnd = onEnd
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        switch session.route(type, flags: flags) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .end:
            finish(cancelPending: type == .tapDisabledByTimeout || type == .tapDisabledByUserInput)
            return Unmanaged.passUnretained(event)
        case .consume:
            guard let native = NSEvent(cgEvent: event) else {
                stop()
                return Unmanaged.passUnretained(event)
            }
            let action = onScroll
            let request = generation
            // Keep the filter callback short: preferences and layout run afterward.
            DispatchQueue.main.async { [weak self] in
                guard self?.generation == request else { return }
                action?(native)
            }
            return nil
        }
    }

    func stop() { finish(cancelPending: true) }

    private func finish(cancelPending: Bool) {
        if cancelPending { generation += 1 }
        session.end()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        let action = onEnd
        onScroll = nil
        onEnd = nil
        if cancelPending {
            action?()
        } else {
            // Apply already-captured ticks before completing a normal key release.
            let request = generation
            DispatchQueue.main.async { [weak self] in
                guard self?.generation == request else { return }
                action?()
            }
        }
    }
}
