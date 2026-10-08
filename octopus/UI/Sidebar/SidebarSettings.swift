import AppKit
import ColorSync

enum SidebarSide: String, CaseIterable, Codable {
    case left, right
}

enum SidebarDesktopScope: String, CaseIterable, Codable {
    case visibleDesktops, allDesktops

    static func saved(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .allDesktops
    }

    var title: String {
        switch self {
        case .visibleDesktops: return "Visible desktops"
        case .allDesktops: return "All desktops"
        }
    }
}

enum SidebarDisplayScope: String, CaseIterable, Codable {
    case allDisplays, currentDisplay

    static func saved(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .allDisplays
    }

    var title: String {
        switch self {
        case .allDisplays: return "All displays"
        case .currentDisplay: return "Current display"
        }
    }
}

enum SidebarActiveAppClickAction: String, CaseIterable {
    case none, hide, minimize

    static func saved(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .minimize
    }

    var title: String {
        switch self {
        case .none: return "None"
        case .hide: return "Hide"
        case .minimize: return "Minimise"
        }
    }
}

enum SidebarIdleBehavior: String, CaseIterable, Codable {
    case fade, hide, stayVisible

    static func saved(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .fade
    }

    var title: String {
        switch self {
        case .fade: return "Fade"
        case .hide: return "Auto-Hide"
        case .stayVisible: return "Alway visible"
        }
    }
}

struct SidebarClickGate {
    static let interval: TimeInterval = 0.23
    private var lastAcceptedTimestamp: TimeInterval?

    mutating func accepts(timestamp: TimeInterval, clickCount: Int) -> Bool {
        if clickCount > 1, let lastAcceptedTimestamp,
           timestamp - lastAcceptedTimestamp < Self.interval { return false }
        self.lastAcceptedTimestamp = timestamp
        return true
    }
}

// A complete snapshot keeps display settings independent of the single-sidebar mode.
struct SidebarConfiguration: Codable, Equatable {
    var enabled: Bool
    var desktopScope: SidebarDesktopScope
    var displayScope: SidebarDisplayScope
    var side: SidebarSide
    var position: Double
    var idleBehavior: SidebarIdleBehavior
    var showSingleWindowMenu: Bool
    var appSpacing: Double
    var fontSize: Double
    var shadowOpacity: Double
    var snapDistance: Double

    init(defaults: UserDefaults? = .standard) {
        enabled = defaults?.object(forKey: "sidebarEnabled") as? Bool ?? true
        desktopScope = .saved(defaults?.string(forKey: "sidebarDesktopScope"))
        displayScope = .saved(defaults?.string(forKey: "sidebarDisplayScope"))
        side = SidebarSide(rawValue: defaults?.string(forKey: "sidebarSide") ?? "") ?? .right
        position = defaults?.object(forKey: "sidebarPosition") as? Double ?? 0.5
        idleBehavior = .saved(defaults?.string(forKey: SidebarSettings.idleBehaviorKey))
        showSingleWindowMenu = defaults?.object(forKey: "sidebarShowSingleWindowMenu") as? Bool ?? true
        appSpacing = defaults?.object(forKey: "sidebarAppSpacing") as? Double ?? SidebarSettings.defaultAppSpacing
        fontSize = defaults?.object(forKey: "sidebarFontSize") as? Double ?? SidebarSettings.defaultFontSize
        shadowOpacity = defaults?.object(forKey: "sidebarShadowOpacity") as? Double ?? SidebarSettings.defaultShadowOpacity
        snapDistance = defaults.map { SidebarSettings.snapDistance(in: $0) } ?? SidebarSettings.defaultSnapDistance
        normalize()
    }

    // Passing no preference store uses the same fallbacks as a fresh installation.
    static var factoryDefaults: Self { Self(defaults: nil) }

    private enum CodingKeys: String, CodingKey {
        case enabled, desktopScope, displayScope, side, position, idleBehavior
        case showSingleWindowMenu, appSpacing, fontSize, shadowOpacity, snapDistance
    }

    init(from decoder: Decoder) throws {
        self.init(defaults: nil)
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try saved.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        desktopScope = try saved.decodeIfPresent(SidebarDesktopScope.self, forKey: .desktopScope) ?? desktopScope
        // Profiles saved before the display filter retain all their existing choices.
        displayScope = try saved.decodeIfPresent(SidebarDisplayScope.self, forKey: .displayScope) ?? .allDisplays
        side = try saved.decodeIfPresent(SidebarSide.self, forKey: .side) ?? side
        position = try saved.decodeIfPresent(Double.self, forKey: .position) ?? position
        idleBehavior = try saved.decodeIfPresent(SidebarIdleBehavior.self, forKey: .idleBehavior) ?? idleBehavior
        showSingleWindowMenu = try saved.decodeIfPresent(Bool.self, forKey: .showSingleWindowMenu) ?? showSingleWindowMenu
        appSpacing = try saved.decodeIfPresent(Double.self, forKey: .appSpacing) ?? appSpacing
        fontSize = try saved.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        shadowOpacity = try saved.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? shadowOpacity
        snapDistance = try saved.decodeIfPresent(Double.self, forKey: .snapDistance) ?? snapDistance
        normalize()
    }

    mutating func normalize() {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        position = clamp(position, 0...1, fallback: 0.5)
        appSpacing = clamp(appSpacing, 0...SidebarSettings.maximumAppSpacing, fallback: SidebarSettings.defaultAppSpacing)
        fontSize = clamp(fontSize, SidebarSettings.minimumFontSize...SidebarSettings.maximumFontSize,
                         fallback: SidebarSettings.defaultFontSize)
        shadowOpacity = clamp(shadowOpacity, 0...SidebarSettings.maximumShadowOpacity,
                              fallback: SidebarSettings.defaultShadowOpacity)
        snapDistance = SidebarSettings.normalizedSnapDistance(snapDistance)
    }

    func saveSingleSidebar(in defaults: UserDefaults = .standard) {
        let values: [String: Any] = [
            "sidebarEnabled": enabled, "sidebarDesktopScope": desktopScope.rawValue,
            "sidebarDisplayScope": displayScope.rawValue,
            "sidebarSide": side.rawValue, "sidebarPosition": position,
            SidebarSettings.idleBehaviorKey: idleBehavior.rawValue,
            "sidebarShowSingleWindowMenu": showSingleWindowMenu, "sidebarAppSpacing": appSpacing,
            "sidebarFontSize": fontSize, "sidebarShadowOpacity": shadowOpacity,
            "sidebarSnapDistance": snapDistance
        ]
        for (key, value) in values { defaults.set(value, forKey: key) }
    }
}

struct SidebarDisplayPreference: Codable, Equatable {
    var name: String
    var configuration: SidebarConfiguration
}

enum SidebarDisplayTarget: Hashable {
    case single
    case display(String)

    var displayID: String? {
        if case .display(let id) = self { return id }
        return nil
    }
}

enum SidebarSettings {
    static let multiDisplayKey = "sidebarMultiDisplayEnabled"
    static let displayPreferencesKey = "sidebarDisplayPreferences"
    static let defaultAppSpacing: Double = 4
    static let maximumAppSpacing: Double = 16
    static let defaultFontSize: Double = 11
    static let minimumFontSize: Double = 9
    static let maximumFontSize: Double = 15
    static let defaultSnapDistance: Double = 200
    static let defaultShadowOpacity: Double = 1
    static let idleSidebarOpacity: CGFloat = 0.35
    static let idleBehaviorKey = "sidebarIdleBehavior"
    static let maximumShadowOpacity: Double = 5
    static let minimumSnapDistance: Double = 20
    static let maximumSnapDistance: Double = 460

    static func normalizedSnapDistance(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSnapDistance }
        return min(max(value, minimumSnapDistance), maximumSnapDistance)
    }

    static func snapDistance(in defaults: UserDefaults = .standard) -> Double {
        normalizedSnapDistance(defaults.object(forKey: "sidebarSnapDistance") as? Double ?? defaultSnapDistance)
    }

    // The former on/off "sidebarAutoHide" maps to Hide / Stay visible; an unset value gets the new default.
    static func migrateLegacyAutoHide(in defaults: UserDefaults = .standard) {
        guard let legacy = defaults.object(forKey: "sidebarAutoHide") as? Bool else { return }
        if defaults.object(forKey: idleBehaviorKey) == nil {
            defaults.set((legacy ? SidebarIdleBehavior.hide : .stayVisible).rawValue, forKey: idleBehaviorKey)
        }
        defaults.removeObject(forKey: "sidebarAutoHide")
    }

    static func registerDefaults() {
        migrateLegacyAutoHide()
        UserDefaults.standard.register(defaults: [
            "sidebarEnabled": true,
            multiDisplayKey: false,
            "sidebarDesktopScope": SidebarDesktopScope.allDesktops.rawValue,
            "sidebarDisplayScope": SidebarDisplayScope.allDisplays.rawValue,
            "sidebarSide": SidebarSide.right.rawValue,
            "sidebarPosition": 0.5,
            "sidebarMonitor": "primary",
            "sidebarShowSingleWindowMenu": true,
            "sidebarAppSpacing": defaultAppSpacing,
            "sidebarFontSize": defaultFontSize,
            "sidebarShadowOpacity": defaultShadowOpacity,
            "sidebarSnapDistance": defaultSnapDistance
        ])
    }

    static func displayPreferences(in defaults: UserDefaults = .standard) -> [String: SidebarDisplayPreference] {
        let saved = defaults.dictionary(forKey: displayPreferencesKey) ?? [:]
        return saved.reduce(into: [:]) { result, pair in
            guard let data = pair.value as? Data,
                  var preference = try? JSONDecoder().decode(SidebarDisplayPreference.self, from: data) else { return }
            preference.configuration.normalize()
            result[pair.key] = preference
        }
    }

    static func configuration(for displayID: String?, in defaults: UserDefaults = .standard) -> SidebarConfiguration {
        if let displayID, let saved = displayPreferences(in: defaults)[displayID] { return saved.configuration }
        return SidebarConfiguration(defaults: defaults)
    }

    static func rememberDisplay(id: String, name: String, in defaults: UserDefaults = .standard) {
        let preference = displayPreferences(in: defaults)[id]
        var configuration = preference?.configuration ?? SidebarConfiguration(defaults: defaults)
        // The global switch controls all sidebars; it is not a new display's Off preference.
        if preference == nil { configuration.enabled = true }
        save(configuration, for: id, name: name, in: defaults)
    }

    static func targets(connectedDisplayIDs: [String], in defaults: UserDefaults = .standard) -> Set<SidebarDisplayTarget> {
        guard defaults.object(forKey: "sidebarEnabled") as? Bool ?? true,
              !connectedDisplayIDs.isEmpty else { return [] }
        guard defaults.bool(forKey: multiDisplayKey) else { return [.single] }
        let preferences = displayPreferences(in: defaults)
        return Set(connectedDisplayIDs.compactMap { id in
            preferences[id]?.configuration.enabled == false ? nil : .display(id)
        })
    }

    static func save(_ configuration: SidebarConfiguration, for displayID: String, name: String,
                     in defaults: UserDefaults = .standard) {
        var normalized = configuration
        normalized.normalize()
        let preference = SidebarDisplayPreference(name: name, configuration: normalized)
        guard displayPreferences(in: defaults)[displayID] != preference else { return }
        guard let data = try? JSONEncoder().encode(preference) else { return }
        var saved = defaults.dictionary(forKey: displayPreferencesKey) ?? [:]
        guard saved[displayID] as? Data != data else { return }
        saved[displayID] = data
        defaults.set(saved, forKey: displayPreferencesKey)
    }

    static func savePosition(_ position: Double, for displayID: String?, in defaults: UserDefaults = .standard) {
        guard position.isFinite else { return }
        let bounded = min(1, max(0, position))
        if let displayID {
            let preference = displayPreferences(in: defaults)[displayID]
            var configuration = preference?.configuration ?? SidebarConfiguration(defaults: defaults)
            configuration.position = bounded
            save(configuration, for: displayID, name: preference?.name ?? "Display", in: defaults)
        } else {
            if defaults.double(forKey: "sidebarPosition") != bounded {
                defaults.set(bounded, forKey: "sidebarPosition")
            }
        }
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func monitorID(_ screen: NSScreen) -> String? {
        displayID(screen).flatMap { monitorID($0) }
    }

    static func monitorID(_ displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func selectedScreen() -> NSScreen? {
        let savedID = UserDefaults.standard.string(forKey: "sidebarMonitor") ?? "primary"
        // NSScreen.main follows keyboard focus; screens.first is the primary display.
        return NSScreen.screens.first(where: { monitorID($0) == savedID }) ?? NSScreen.screens.first
    }
}

enum SidebarLayout {
    static func scrolledPosition(_ position: Double, deltaY: Double, precise: Bool,
                                 inverted: Bool, availableTravel: CGFloat) -> Double? {
        guard position.isFinite, deltaY.isFinite, deltaY != 0,
              availableTravel.isFinite, availableTravel > 0 else { return nil }
        // Wheel events use lines; high-resolution devices already report points.
        // Undo Natural Scrolling so rolling the wheel up moves the sidebar up.
        let distance = deltaY * (inverted ? -1 : 1) * (precise ? 1 : 8)
        guard distance.isFinite else { return nil }
        return min(1, max(0, position - distance / Double(availableTravel)))
    }

    // Keep the icon close to the display edge while leaving room for its label.
    static let width: CGFloat = 86
    // Extra canvas toward the desktop for the magnified frost's soft edges.
    static let drawingPadding: CGFloat = 36
    static let menuGap: CGFloat = 2
    // Keep the icon and title close together so the sidebar reads as a compact dock.
    static let rowHeight: CGFloat = 86
    static let desktopSeparatorHeight: CGFloat = 12
    static let iconSize: CGFloat = 40
    static let iconSlotHeight: CGFloat = 46
    static let labelHeight: CGFloat = 40
    static let magnificationGrowth: CGFloat = 0.32
    static let verticalPadding: CGFloat = 4
    static let menuRowHeight: CGFloat = 34
    static let menuPadding: CGFloat = 4
    static let menuActionHeight: CGFloat = 34
    static let menuWindowActionWidth: CGFloat = 30

    static var appSpacing: CGFloat {
        CGFloat(min(max(UserDefaults.standard.double(forKey: "sidebarAppSpacing"), 0),
                    SidebarSettings.maximumAppSpacing))
    }

    static func sidebarFrame(in visibleFrame: CGRect, count: Int, side: SidebarSide, position: Double,
                             appSpacing: CGFloat = SidebarLayout.appSpacing, separatorCount: Int = 0,
                             contentHeight: CGFloat? = nil) -> CGRect {
        let gaps = CGFloat(max(0, count - 1)) * appSpacing
        let separators = CGFloat(max(0, separatorCount)) * (desktopSeparatorHeight + appSpacing)
        let height = min(max(rowHeight, contentHeight ?? (CGFloat(count) * rowHeight + gaps + separators + 16)), visibleFrame.height)
        let width = min(Self.width, visibleFrame.width)
        return CGRect(
            x: side == .left ? visibleFrame.minX : visibleFrame.maxX - width,
            y: visibleFrame.minY + (visibleFrame.height - height) * (1 - min(1, max(0, position))),
            width: width, height: height
        )
    }

    static func menuFrame(size: CGSize, icon: CGRect, screen: CGRect, side: SidebarSide) -> CGRect {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let x = side == .left ? icon.maxX + menuGap : icon.minX - menuGap - width
        let y = icon.midY - height / 2 - 18
        return CGRect(
            x: min(max(x, screen.minX), screen.maxX - width),
            y: min(max(y, screen.minY), screen.maxY - height),
            width: width, height: height
        )
    }

    static func acceptsSidebarPointer(at point: CGPoint, sidebar: CGRect, menu: CGRect?) -> Bool {
        sidebar.contains(point) && !(menu?.contains(point) ?? false)
    }
}
