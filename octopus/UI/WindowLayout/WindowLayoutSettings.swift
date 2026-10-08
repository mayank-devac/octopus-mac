import Foundation

enum WindowLayoutSelection: String, CaseIterable {
    case mostRecent, allNormal

    static func saved(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .mostRecent }
    var title: String { self == .mostRecent ? "Most recently used other window" : "All other normal windows" }
}

// Neighbour adjustment follows accepted Octopus snaps; normal window movement is unchanged.
enum WindowLayoutSettings {
    static let enabledKey = "windowLayoutEnabled"
    static let selectionKey = "windowLayoutSelection"
    static let readabilityMinimum = CGSize(width: 320, height: 200)

    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }
    static func selection(in defaults: UserDefaults = .standard) -> WindowLayoutSelection {
        .saved(defaults.string(forKey: selectionKey))
    }
}
