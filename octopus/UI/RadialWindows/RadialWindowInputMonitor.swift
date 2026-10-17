import AppKit

// Pure ownership state: cancelling UI never leaks the up event of a consumed press.
struct RadialWindowInputSession {
    enum Trigger { case mouse, keyboard(NSEvent.ModifierFlags) }
    enum Route: Equatable { case pass, consume, beginMouse, pointer, finish, cancel, key(UInt16), scroll }
    private(set) var trigger: Trigger?
    private(set) var ownsMiddle = false
    private var ownedKeys = Set<UInt16>()
    private var keyboardLatch: NSEvent.ModifierFlags?
    private var triggerKey: UInt16?
    var hasOwnedEvents: Bool { ownsMiddle || !ownedKeys.isEmpty }

    mutating func beginKeyboard(modifiers: NSEvent.ModifierFlags, key: UInt16) -> Bool {
        guard trigger == nil, keyboardLatch == nil, !modifiers.isEmpty else { return false }
        trigger = .keyboard(modifiers)
        keyboardLatch = modifiers
        triggerKey = key
        return true
    }

    mutating func cancel() { trigger = nil }

    mutating func interrupt(modifiers: NSEvent.ModifierFlags) {
        cancel()
        if let latch = keyboardLatch,
           !modifiers.intersection(MouseShortcut.supportedModifiers).isSuperset(of: latch) {
            keyboardLatch = nil
        }
    }

    mutating func route(_ type: CGEventType, button: Int = 0, key: UInt16 = 0,
                        flags: NSEvent.ModifierFlags = [], repeating: Bool = false, canBeginMouse: Bool = false) -> Route {
        let modifiers = flags.intersection(MouseShortcut.supportedModifiers)
        if type == .flagsChanged {
            if let latch = keyboardLatch, !modifiers.isSuperset(of: latch) { keyboardLatch = nil }
            if case .keyboard(let required) = trigger, !modifiers.isSuperset(of: required) {
                trigger = nil
                return .finish
            }
            return .pass
        }
        if type == .keyUp {
            return ownedKeys.remove(key) != nil ? .consume : .pass
        }
        if type == .keyDown, trigger == nil, ownedKeys.contains(key) {
            if repeating { return .consume }
            // A fresh down means the old release was missed while capture was interrupted.
            ownedKeys.remove(key)
        }
        if type == .otherMouseUp, button == 2, ownsMiddle {
            ownsMiddle = false
            if case .mouse = trigger { trigger = nil; return .finish }
            return .consume
        }
        if type == .otherMouseDown, button == 2, trigger == nil {
            ownsMiddle = false
            guard modifiers.isEmpty, canBeginMouse else { return .pass }
            ownsMiddle = true
            triggerKey = nil
            trigger = .mouse
            return .beginMouse
        }
        guard trigger != nil else { return .pass }
        switch type {
        case .mouseMoved: return .pointer
        case .otherMouseDragged: return button == 2 && ownsMiddle ? .pointer : .pass
        case .scrollWheel: return .scroll
        case .keyDown:
            if key == triggerKey { ownedKeys.insert(key); return .consume }
            if [UInt16(53), 36, 76, 123, 124, 125, 126, 116, 121].contains(key) {
                ownedKeys.insert(key)
                if key == 53 { trigger = nil; return .cancel }
                return .key(key)
            }
            trigger = nil
            return .cancel
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            trigger = nil
            return .cancel
        default: return .pass
        }
    }
}

struct RadialWindowScrollPager {
    private var accumulated: CGFloat = 0
    private var lastStep: TimeInterval = -.infinity
    private var lastInput: TimeInterval = -.infinity
    mutating func step(delta: CGFloat, precise: Bool, momentum: Bool, time: TimeInterval) -> Int? {
        guard !momentum, delta != 0 else { return nil }
        if time - lastInput > 0.4 { accumulated = 0 }
        lastInput = time
        if accumulated * delta < 0 { accumulated = 0 }
        accumulated += delta
        guard time - lastStep >= 0.16, !precise || abs(accumulated) >= 36 else { return nil }
        let direction = accumulated < 0 ? 1 : -1
        accumulated = 0
        lastStep = time
        return direction
    }
}

// Follows WindowTabGroupKeyboardMonitor: native calls and SwiftUI changes run after the tap returns.
@MainActor
final class RadialWindowInputMonitor {
    var canBeginMouse: () -> Bool = { false }
    var onBeginMouse: (CGPoint) -> Void = { _ in }
    var onPointer: (CGPoint) -> Void = { _ in }
    var onFinish: (CGPoint) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onOtherInput: () -> Void = {}
    var onKey: (UInt16) -> Void = { _ in }
    var onScroll: (CGFloat, Bool, Bool) -> Void = { _, _, _ in }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var session = RadialWindowInputSession()
    private var generation = 0
    private var stopping = false
    private var screenTop: CGFloat = 0
    var isInstalled: Bool { tap != nil }

    func beginKeyboard(modifiers: NSEvent.ModifierFlags, key: UInt16) -> Bool {
        session.beginKeyboard(modifiers: modifiers, key: key)
    }
    func cancel() { generation += 1; session.cancel() }
    func updateScreenCoordinates() { screenTop = NSScreen.screens.first?.frame.maxY ?? 0 }

    func start() -> Bool {
        stopping = false
        if tap != nil { return true }
        updateScreenCoordinates()
        guard AXIsProcessTrusted() else { return false }
        let events: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved,
            .leftMouseDown, .rightMouseDown, .keyDown, .keyUp, .flagsChanged, .scrollWheel]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    Unmanaged<RadialWindowInputMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { CFMachPortInvalidate(tap); return false }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            generation += 1
            session.interrupt(modifiers: NSEvent.modifierFlags)
            DispatchQueue.main.async { [weak self] in self?.onCancel() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let route = session.route(type, button: Int(event.getIntegerValueField(.mouseEventButtonNumber)),
            key: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
            repeating: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            canBeginMouse: type == .otherMouseDown && canBeginMouse())
        if stopping && !session.hasOwnedEvents {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stopping, !self.session.hasOwnedEvents else { return }
                self.stop()
            }
        }
        if route == .pass && [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            DispatchQueue.main.async { [weak self] in self?.onOtherInput() }
        }
        if route == .pass { return Unmanaged.passUnretained(event) }
        if route == .consume { return nil }
        // Capture the location now; reading the later cursor position would skip intermediate targets.
        let point = CGPoint(x: event.location.x, y: screenTop - event.location.y)
        let precise = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let delta = event.getDoubleValueField(precise ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
        let request = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == request else { return }
            switch route {
            case .beginMouse: self.onBeginMouse(point)
            case .pointer: self.onPointer(point)
            case .finish: self.onFinish(point)
            case .cancel: self.onCancel()
            case .key(let key): self.onKey(key)
            case .scroll: self.onScroll(delta, precise, momentum)
            case .pass, .consume: break
            }
        }
        // Modifier releases and unrelated cancelling input still reach the original app.
        if route == .cancel && type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 { return nil }
        if type == .flagsChanged || route == .cancel || type == .mouseMoved { return Unmanaged.passUnretained(event) }
        return nil
    }

    func stopWhenDrained() {
        session.cancel()
        stopping = true
        if !session.hasOwnedEvents { stop() }
    }

    func stop() {
        generation += 1
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        session = RadialWindowInputSession()
    }
}
