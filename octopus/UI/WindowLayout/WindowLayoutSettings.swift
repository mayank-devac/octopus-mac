import Foundation

enum WindowSnapMode: String, CaseIterable {
    case legacy, current

    static func saved(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .legacy }
    var title: String { self == .legacy ? "Legacy (default)" : "Current (Beta)" }
}

enum WindowLayoutSelection: String, CaseIterable {
    case mostRecent, allNormal

    static func saved(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .mostRecent }
    var title: String { self == .mostRecent ? "Most recently used window" : "All windows (limited)" }
}

enum VisibleDisplayMoveSize: String, CaseIterable {
    case original, fullScreen

    static func saved(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .fullScreen }
    var title: String { self == .original ? "Original size" : "Full screen" }
}

// Neighbour adjustment follows accepted Octopus snaps; normal window movement is unchanged.
enum WindowLayoutSettings {
    static let modeKey = "windowSnapMode"
    static let enabledKey = "windowLayoutEnabled"
    static let selectionKey = "windowLayoutSelection"
    static let moveSizeKey = "visibleDisplayMoveSize"
    static let maximumWindowsKey = "windowLayoutMaximumWindows"
    static let defaultMaximumWindows = 3
    static let maximumWindowsRange = 2...8

    static func normalizedMaximumWindows(_ value: Int) -> Int {
        min(maximumWindowsRange.upperBound, max(maximumWindowsRange.lowerBound, value))
    }

    static func maximumWindows(in defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: maximumWindowsKey) != nil else { return defaultMaximumWindows }
        return normalizedMaximumWindows(defaults.integer(forKey: maximumWindowsKey))
    }

    static let readabilityMinimum = CGSize(width: 320, height: 200)

    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }
    static func mode(in defaults: UserDefaults = .standard) -> WindowSnapMode {
        .saved(defaults.string(forKey: modeKey))
    }
    static func selection(in defaults: UserDefaults = .standard) -> WindowLayoutSelection {
        .saved(defaults.string(forKey: selectionKey))
    }
    static func tabGroupingEnabled(in defaults: UserDefaults = .standard) -> Bool {
        enabled(in: defaults) && selection(in: defaults) == .mostRecent
    }
    static func moveSize(in defaults: UserDefaults = .standard) -> VisibleDisplayMoveSize {
        .saved(defaults.string(forKey: moveSizeKey))
    }
}
