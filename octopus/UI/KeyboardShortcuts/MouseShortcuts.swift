import AppKit
import Combine

struct MouseShortcut: Equatable {
    static let supportedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    let button: Int
    let modifiers: NSEvent.ModifierFlags

    static let left = MouseShortcut(button: 0)
    static let right = MouseShortcut(button: 1)

    init(button: Int, modifiers: NSEvent.ModifierFlags = []) {
        self.button = button
        self.modifiers = modifiers.intersection(Self.supportedModifiers)
    }

    init?(saved: String) {
        let fields = saved.split(separator: ":")
        guard fields.count == 2, let button = Int(fields[0]), (0...31).contains(button),
              let flags = UInt(fields[1]), flags & ~Self.supportedModifiers.rawValue == 0 else { return nil }
        self.init(button: button, modifiers: NSEvent.ModifierFlags(rawValue: flags))
    }

    var saved: String { "\(button):\(modifiers.rawValue)" }
    var isValid: Bool { (0...31).contains(button) }
    var title: String {
        var keys = ""
        if modifiers.contains(.control) { keys += "⌃" }
        if modifiers.contains(.option) { keys += "⌥" }
        if modifiers.contains(.shift) { keys += "⇧" }
        if modifiers.contains(.command) { keys += "⌘" }
        let name = button == 0 ? "Left click" : button == 1 ? "Right click" : button == 2 ? "Middle click" : "Mouse button \(button + 1)"
        return keys.isEmpty ? name : "\(keys) + \(name)"
    }
}

enum SidebarPositionScrollShortcut {
    static let key = "sidebarPositionScrollModifiers"
    static let defaultModifiers: NSEvent.ModifierFlags = .control

    static func read(in defaults: UserDefaults) -> NSEvent.ModifierFlags {
        guard let saved = defaults.string(forKey: key), let raw = UInt(saved),
              raw & ~MouseShortcut.supportedModifiers.rawValue == 0 else { return defaultModifiers }
        return NSEvent.ModifierFlags(rawValue: raw)
    }

    static func matches(_ eventModifiers: NSEvent.ModifierFlags, required: NSEvent.ModifierFlags) -> Bool {
        !required.isEmpty && eventModifiers.intersection(MouseShortcut.supportedModifiers) == required
    }
}

enum SidebarCornerSnapShortcut {
    static let key = "sidebarCornerSnapModifiers"
    static let defaultModifiers: NSEvent.ModifierFlags = [.control, .option, .shift]

    static func read(in defaults: UserDefaults) -> NSEvent.ModifierFlags {
        guard let saved = defaults.string(forKey: key), let raw = UInt(saved),
              raw & ~MouseShortcut.supportedModifiers.rawValue == 0 else { return defaultModifiers }
        return NSEvent.ModifierFlags(rawValue: raw)
    }

    static func matches(_ flags: NSEvent.ModifierFlags, required: NSEvent.ModifierFlags) -> Bool {
        !required.isEmpty && flags.intersection(required) == required
    }

    // The corner chord augments the configured drag; it never changes its mouse button.
    static func allowsDrag(_ input: MouseShortcut, binding: MouseShortcut?, cornerModifiers: NSEvent.ModifierFlags) -> Bool {
        guard let binding, input.button == binding.button else { return false }
        return input.modifiers == binding.modifiers
            || (!cornerModifiers.isEmpty && input.modifiers == binding.modifiers.union(cornerModifiers))
    }
}

enum MouseShortcutAction: String, CaseIterable {
    case minimize, place, hide

    var title: String {
        switch self {
        case .minimize: return "Minimise / restore window"
        case .place: return "Resize and snap window"
        case .hide: return "Hide app"
        }
    }

    var key: String { "sidebarMouseShortcut.\(rawValue)" }
    var defaultShortcut: MouseShortcut {
        switch self {
        case .hide: return .right
        case .minimize, .place: return .left
        }
    }
}

struct MouseShortcutBindings: Equatable {
    var minimize: MouseShortcut?
    var place: MouseShortcut?
    var hide: MouseShortcut?

    init(defaults: UserDefaults) {
        func read(_ action: MouseShortcutAction) -> MouseShortcut? {
            guard let saved = defaults.string(forKey: action.key) else { return action.defaultShortcut }
            if saved.isEmpty { return nil } // Clearing must remain disabled after a restart.
            return MouseShortcut(saved: saved) ?? action.defaultShortcut
        }
        minimize = read(.minimize)
        place = read(.place)
        hide = read(.hide)
        // A manually edited/corrupt preference must never trigger two click actions.
        if minimize != nil && minimize == hide { minimize = nil }
    }

    subscript(action: MouseShortcutAction) -> MouseShortcut? {
        get {
            switch action {
            case .minimize: return minimize
            case .place: return place
            case .hide: return hide
            }
        }
        set {
            switch action {
            case .minimize: minimize = newValue
            case .place: place = newValue
            case .hide: hide = newValue
            }
        }
    }

    func clickAction(for shortcut: MouseShortcut) -> MouseShortcutAction? {
        if hide == shortcut { return .hide }
        if minimize == shortcut { return .minimize }
        return nil
    }
}

@MainActor
final class MouseShortcutStore: ObservableObject {
    static let shared = MouseShortcutStore()
    @Published private(set) var bindings: MouseShortcutBindings
    @Published private(set) var positionScrollModifiers: NSEvent.ModifierFlags
    @Published private(set) var cornerSnapModifiers: NSEvent.ModifierFlags
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bindings = MouseShortcutBindings(defaults: defaults)
        positionScrollModifiers = SidebarPositionScrollShortcut.read(in: defaults)
        cornerSnapModifiers = SidebarCornerSnapShortcut.read(in: defaults)
    }

    func setCornerSnapModifiers(_ modifiers: NSEvent.ModifierFlags) {
        let supported = modifiers.intersection(MouseShortcut.supportedModifiers)
        defaults.set(String(supported.rawValue), forKey: SidebarCornerSnapShortcut.key)
        cornerSnapModifiers = supported
    }

    func resetCornerSnapModifiers() { setCornerSnapModifiers(SidebarCornerSnapShortcut.defaultModifiers) }

    func setPositionScrollModifiers(_ modifiers: NSEvent.ModifierFlags) {
        let supported = modifiers.intersection(MouseShortcut.supportedModifiers)
        defaults.set(String(supported.rawValue), forKey: SidebarPositionScrollShortcut.key)
        positionScrollModifiers = supported
    }

    func resetPositionScrollModifiers() {
        setPositionScrollModifiers(SidebarPositionScrollShortcut.defaultModifiers)
    }

    // Return an explanation without changing the old binding when recording conflicts.
    @discardableResult
    func assign(_ shortcut: MouseShortcut?, to action: MouseShortcutAction) -> String? {
        if let shortcut {
            guard shortcut.isValid else { return "This mouse button is not supported." }
            if shortcut == MouseShortcut(button: 2), defaults.bool(forKey: RadialWindowSettings.mouseKey) {
                return "Middle click is reserved for the radial window selector. Disable it there first."
            }
            let other: MouseShortcutAction? = action == .hide ? .minimize : action == .minimize ? .hide : nil
            if let other, bindings[other] == shortcut {
                return "\(shortcut.title) is already assigned to \(other.title.lowercased()). Choose another shortcut or clear that assignment first."
            }
        }
        var next = bindings
        next[action] = shortcut
        defaults.set(shortcut?.saved ?? "", forKey: action.key)
        bindings = next
        return nil
    }

    @discardableResult
    func reset(_ action: MouseShortcutAction) -> String? {
        assign(action.defaultShortcut, to: action)
    }

    func resetAll() {
        // Restore the full set together; intermediate click conflicts must not block it.
        for action in MouseShortcutAction.allCases {
            defaults.set(action.defaultShortcut.saved, forKey: action.key)
        }
        bindings = MouseShortcutBindings(defaults: defaults)
        resetPositionScrollModifiers()
        resetCornerSnapModifiers()
    }
}
