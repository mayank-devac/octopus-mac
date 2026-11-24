import AppKit
import ColorSync

// Keep app palettes below the sidebar, and its interaction surfaces above it.
// These levels remain below modal panels and system menus.
enum SidebarWindowLevels {
    static let sidebar = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    static let menu = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
    static let dragPreview = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
    static let dragIcon = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 4)
    // The notch occupies menu-bar space, but stays below opened popup menus.
    static let notch = NSWindow.Level.statusBar
    // Menus opened from the notch bar must draw over it, still below system popup menus.
    static let notchMenu = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
}

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
    case fade, hide, stayVisible, compact, notch

    /// Behavior used when the user has not chosen one yet ("Auto-Hide" in Preferences).
    static let defaultBehavior: Self = .hide

    /// Decodes a persisted raw value, falling back to `defaultBehavior` when it is missing or unknown.
    static func saved(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? defaultBehavior
    }

    var title: String {
        switch self {
        case .fade: return "Fade"
        case .hide: return "Auto-Hide"
        case .stayVisible: return "Alway visible"
        case .compact: return "Compact"
        case .notch: return "Mac Notch"
        }
    }

    // Modes that keep the sidebar over windows offer Delay opening; Auto-Hide and Mac Notch already stay out of the way.
    var supportsDelayedOpening: Bool { self == .fade || self == .stayVisible || self == .compact }

    var delayedOpeningChoices: [SidebarDelayedOpening] {
        guard supportsDelayedOpening else { return [] }
        return SidebarDelayedOpening.allCases.filter { $0 != .stepAside || self != .stayVisible }
    }
}

// How Delay opening keeps the sidebar out of the way until the pointer rests on it.
enum SidebarDelayedOpening: String, CaseIterable, Codable {
    case off
    // The sidebar works normally, then fades and lets clicks through once the pointer rests on it unused for the delay.
    case stepAside
    // The sidebar hides while idle and slides in after the pointer rests at the screen edge.
    case hideUntilEdge

    static let defaultChoice: Self = .off

    static func saved(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? defaultChoice
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .stepAside: return "Step aside"
        case .hideUntilEdge: return "Hide until edge"
        }
    }

    // Preferences copy for the delay slider; Off has no delay to set.
    var delayCopy: (title: String, help: String)? {
        switch self {
        case .off: return nil
        case .stepAside: return ("Closing delay", "How long the pointer must rest on the sidebar before it steps aside.")
        case .hideUntilEdge: return ("Opening delay", "How long the pointer must rest at the edge before the sidebar opens.")
        }
    }
}

// Floating: icons float over the desktop.
// Dock: icons held inside a rounded bar.
enum SidebarStyle: String, CaseIterable, Codable {
    case dock, floating

    static let key = "sidebarStyle"
    static let defaultStyle: Self = .dock

    // Builds before the rename stored Dock as "inside" and Floating as "outside".
    init?(storedValue: String) {
        switch storedValue {
        case "inside": self = .dock
        case "outside": self = .floating
        default: self.init(rawValue: storedValue)
        }
    }

    // An unknown value falls back to the default style instead of failing the whole saved configuration.
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(storedValue: value) ?? Self.defaultStyle
    }

    static func saved(_ value: String?) -> Self {
        value.flatMap(Self.init(storedValue:)) ?? defaultStyle
    }

    // Applied the first time a style is chosen and when nothing is saved yet.
    var defaultShowsWindowTitles: Bool { self == .dock }
    var defaultShowsSingleWindowMenu: Bool { true }
    var defaultChoices: SidebarStyleChoices {
        SidebarStyleChoices(showsWindowTitles: defaultShowsWindowTitles,
                            showSingleWindowMenu: defaultShowsSingleWindowMenu)
    }

    var monitorHeaderHeight: CGFloat {
        self == .dock ? SidebarLayout.dockSeparatorHeight : SidebarMonitor.headerHeight
    }

    var desktopSeparatorHeight: CGFloat {
        self == .dock ? SidebarLayout.dockSeparatorHeight : SidebarLayout.desktopSeparatorHeight
    }

    var emptyHeight: CGFloat {
        self == .dock ? 0 : SidebarMonitor.emptyHeight
    }
}

// The title and single-window menu choices one style remembers while another style is active.
struct SidebarStyleChoices: Codable, Equatable {
    var showsWindowTitles: Bool
    var showSingleWindowMenu: Bool
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
    var style: SidebarStyle
    var compactShowsIcons: Bool
    var autoHideShowsEdgeMark: Bool
    // Edge mark color as "#RRGGBB"; nil follows the system appearance.
    var autoHideEdgeMarkColor: String?
    var showSingleWindowMenu: Bool
    var showsWindowTitles: Bool
    // Choices of the styles that are not active, keyed by style raw value.
    var inactiveStyleChoices: [String: SidebarStyleChoices]
    var appSpacing: Double
    var fontSize: Double
    var shadowOpacity: Double
    // Opacity of the vertical Dock's glass panel; Dock style shows this in place of shadow opacity.
    var dockOpacity: Double
    var virtualNotchWidth: Double
    // Delay opening: only applies to modes where `idleBehavior.supportsDelayedOpening`.
    var delayedOpening: SidebarDelayedOpening
    // Seconds the pointer must rest at the edge before Hide until edge opens the sidebar.
    var openingDelay: Double
    // Seconds the pointer must rest on the sidebar before Step aside fades it.
    var closingDelay: Double

    init(defaults: UserDefaults? = .standard) {
        enabled = defaults?.object(forKey: "sidebarEnabled") as? Bool ?? true
        desktopScope = .saved(defaults?.string(forKey: "sidebarDesktopScope"))
        displayScope = .saved(defaults?.string(forKey: "sidebarDisplayScope"))
        side = SidebarSide(rawValue: defaults?.string(forKey: "sidebarSide") ?? "") ?? .right
        position = defaults?.object(forKey: "sidebarPosition") as? Double ?? 0.5
        idleBehavior = .saved(defaults?.string(forKey: SidebarSettings.idleBehaviorKey))
        style = .saved(defaults?.string(forKey: SidebarStyle.key))
        compactShowsIcons = defaults?.bool(forKey: SidebarSettings.compactIconsKey) ?? false
        autoHideShowsEdgeMark = defaults?.object(forKey: SidebarSettings.edgeMarkKey) as? Bool ?? true
        autoHideEdgeMarkColor = defaults?.string(forKey: SidebarSettings.edgeMarkColorKey)
        showSingleWindowMenu = defaults?.object(forKey: SidebarSettings.singleWindowMenuKey) as? Bool
            ?? style.defaultShowsSingleWindowMenu
        showsWindowTitles = defaults?.object(forKey: SidebarSettings.windowTitlesKey) as? Bool
            ?? style.defaultShowsWindowTitles
        inactiveStyleChoices = defaults?.data(forKey: SidebarSettings.inactiveStyleChoicesKey)
            .flatMap { try? JSONDecoder().decode([String: SidebarStyleChoices].self, from: $0) } ?? [:]
        appSpacing = defaults?.object(forKey: "sidebarAppSpacing") as? Double ?? SidebarSettings.defaultAppSpacing
        fontSize = defaults?.object(forKey: "sidebarFontSize") as? Double ?? SidebarSettings.defaultFontSize
        shadowOpacity = defaults?.object(forKey: "sidebarShadowOpacity") as? Double ?? SidebarSettings.defaultShadowOpacity
        dockOpacity = defaults?.object(forKey: SidebarSettings.dockOpacityKey) as? Double ?? SidebarSettings.defaultDockOpacity
        virtualNotchWidth = defaults?.object(forKey: SidebarSettings.virtualNotchWidthKey) as? Double
            ?? SidebarSettings.defaultVirtualNotchWidth
        delayedOpening = .saved(defaults?.string(forKey: SidebarSettings.delayedOpeningKey))
        openingDelay = defaults?.object(forKey: SidebarSettings.openingDelayKey) as? Double
            ?? SidebarSettings.defaultOpeningDelay
        closingDelay = defaults?.object(forKey: SidebarSettings.closingDelayKey) as? Double
            ?? SidebarSettings.defaultClosingDelay
        normalize()
    }

    // The Delay opening choice in effect; Off when it is unavailable for the visibility mode.
    var activeDelayedOpening: SidebarDelayedOpening {
        idleBehavior.delayedOpeningChoices.contains(delayedOpening) ? delayedOpening : .off
    }

    // Hide until edge is Auto-Hide with a reveal delay, so the view and `SidebarPresentation`
    // both draw from this instead of handling it as another mode.
    var effectiveIdleBehavior: SidebarIdleBehavior {
        activeDelayedOpening == .hideUntilEdge ? .hide : idleBehavior
    }

    // Passing no preference store uses the same fallbacks as a fresh installation.
    static var factoryDefaults: Self { Self(defaults: nil) }

    ////////////////////
    //// Switch style
    /// Each style keeps its own titles and single-window menu choices.
    // The outgoing style's choices are stored; the incoming style restores its own, or its defaults.

    var selectedStyle: SidebarStyle {
        get { style }
        set {
            guard newValue != style else { return }
            inactiveStyleChoices[style.rawValue] = SidebarStyleChoices(
                showsWindowTitles: showsWindowTitles, showSingleWindowMenu: showSingleWindowMenu)
            let choices = inactiveStyleChoices.removeValue(forKey: newValue.rawValue) ?? newValue.defaultChoices
            style = newValue
            showsWindowTitles = choices.showsWindowTitles
            showSingleWindowMenu = choices.showSingleWindowMenu
        }
    }

    //// Switching back and forth never loses a user's change.
    //////////////////

    // Rows reserve space for the title below the icon only while titles are shown. Titles take up to
    // two lines everywhere; the vertical Dock sizes those lines to the font, while Floating and the
    // Mac Notch bar keep a fixed row.
    var rowHeight: CGFloat {
        guard showsWindowTitles else { return SidebarLayout.iconOnlyRowHeight }
        guard usesFontSizedTitleRows else { return SidebarLayout.rowHeight }
        return SidebarLayout.iconSlotHeight + SidebarLayout.titleHeight(fontSize: fontSize) - SidebarLayout.dockTitleLift
    }

    var usesFontSizedTitleRows: Bool { style == .dock && idleBehavior != .notch }

    private enum CodingKeys: String, CodingKey {
        case enabled, desktopScope, displayScope, side, position, idleBehavior, style, compactShowsIcons, autoHideShowsEdgeMark, autoHideEdgeMarkColor
        case showSingleWindowMenu, showsWindowTitles, inactiveStyleChoices, appSpacing, fontSize, shadowOpacity, dockOpacity, virtualNotchWidth
        case delayedOpening, openingDelay, closingDelay
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
        style = try saved.decodeIfPresent(SidebarStyle.self, forKey: .style) ?? style
        compactShowsIcons = try saved.decodeIfPresent(Bool.self, forKey: .compactShowsIcons) ?? false
        autoHideShowsEdgeMark = try saved.decodeIfPresent(Bool.self, forKey: .autoHideShowsEdgeMark) ?? true
        autoHideEdgeMarkColor = try saved.decodeIfPresent(String.self, forKey: .autoHideEdgeMarkColor)
        // Older profiles without these choices get the defaults of their saved style.
        showSingleWindowMenu = try saved.decodeIfPresent(Bool.self, forKey: .showSingleWindowMenu)
            ?? style.defaultShowsSingleWindowMenu
        showsWindowTitles = try saved.decodeIfPresent(Bool.self, forKey: .showsWindowTitles) ?? style.defaultShowsWindowTitles
        inactiveStyleChoices = try saved.decodeIfPresent([String: SidebarStyleChoices].self,
                                                         forKey: .inactiveStyleChoices) ?? [:]
        appSpacing = try saved.decodeIfPresent(Double.self, forKey: .appSpacing) ?? appSpacing
        fontSize = try saved.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        shadowOpacity = try saved.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? shadowOpacity
        dockOpacity = try saved.decodeIfPresent(Double.self, forKey: .dockOpacity) ?? dockOpacity
        virtualNotchWidth = try saved.decodeIfPresent(Double.self, forKey: .virtualNotchWidth) ?? virtualNotchWidth
        // Decoded as text so an unknown choice falls back instead of failing the whole configuration.
        delayedOpening = .saved(try saved.decodeIfPresent(String.self, forKey: .delayedOpening))
        openingDelay = try saved.decodeIfPresent(Double.self, forKey: .openingDelay) ?? openingDelay
        closingDelay = try saved.decodeIfPresent(Double.self, forKey: .closingDelay) ?? closingDelay
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
        dockOpacity = clamp(dockOpacity, 0...1, fallback: SidebarSettings.defaultDockOpacity)
        virtualNotchWidth = clamp(virtualNotchWidth, SidebarSettings.virtualNotchWidthRange,
                                 fallback: SidebarSettings.defaultVirtualNotchWidth)
        openingDelay = clamp(openingDelay, SidebarSettings.openingDelayRange,
                             fallback: SidebarSettings.defaultOpeningDelay)
        closingDelay = clamp(closingDelay, SidebarSettings.openingDelayRange,
                             fallback: SidebarSettings.defaultClosingDelay)
    }

    func saveSingleSidebar(in defaults: UserDefaults = .standard) {
        let values: [String: Any] = [
            "sidebarEnabled": enabled, "sidebarDesktopScope": desktopScope.rawValue,
            "sidebarDisplayScope": displayScope.rawValue,
            "sidebarSide": side.rawValue, "sidebarPosition": position,
            SidebarSettings.idleBehaviorKey: idleBehavior.rawValue,
            SidebarStyle.key: style.rawValue,
            SidebarSettings.compactIconsKey: compactShowsIcons,
            SidebarSettings.edgeMarkKey: autoHideShowsEdgeMark,
            SidebarSettings.singleWindowMenuKey: showSingleWindowMenu,
            SidebarSettings.windowTitlesKey: showsWindowTitles,
            "sidebarAppSpacing": appSpacing,
            "sidebarFontSize": fontSize, "sidebarShadowOpacity": shadowOpacity,
            SidebarSettings.dockOpacityKey: dockOpacity,
            SidebarSettings.virtualNotchWidthKey: virtualNotchWidth,
            SidebarSettings.delayedOpeningKey: delayedOpening.rawValue,
            SidebarSettings.openingDelayKey: openingDelay,
            SidebarSettings.closingDelayKey: closingDelay
        ]
        for (key, value) in values { defaults.set(value, forKey: key) }
        defaults.set(autoHideEdgeMarkColor, forKey: SidebarSettings.edgeMarkColorKey)
        defaults.set(try? JSONEncoder().encode(inactiveStyleChoices), forKey: SidebarSettings.inactiveStyleChoicesKey)
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
    static let compactIconsKey = "sidebarCompactShowsIcons"
    static let edgeMarkKey = "sidebarAutoHideEdgeMark"
    static let edgeMarkColorKey = "sidebarAutoHideEdgeMarkColor"
    static let singleWindowMenuKey = "sidebarShowSingleWindowMenu"
    static let windowTitlesKey = "sidebarShowWindowTitles"
    static let inactiveStyleChoicesKey = "sidebarInactiveStyleChoices"
    static let virtualNotchWidthKey = "sidebarVirtualNotchWidth"
    static let defaultVirtualNotchWidth: Double = 200
    static let virtualNotchWidthRange: ClosedRange<Double> = 100...400
    static let delayedOpeningKey = "sidebarDelayedOpening"
    static let openingDelayKey = "sidebarOpeningDelay"
    static let closingDelayKey = "sidebarClosingDelay"
    static let openingDelayRange: ClosedRange<Double> = 0.1...5.0
    static let defaultOpeningDelay: Double = 0.3
    static let defaultClosingDelay: Double = 0.8
    static let multiDisplayKey = "sidebarMultiDisplayEnabled"
    static let displayPreferencesKey = "sidebarDisplayPreferences"
    // Display last chosen in the Settings "Display" picker, so reopening Settings shows the same monitor.
    static let settingsSelectedDisplayKey = "sidebarSettingsSelectedDisplay"
    static let defaultAppSpacing: Double = 4
    static let maximumAppSpacing: Double = 16
    static let defaultFontSize: Double = 10
    static let minimumFontSize: Double = 9
    static let maximumFontSize: Double = 15
    static let defaultSnapDistance: Double = 200
    static let defaultShadowOpacity: Double = 1
    static let defaultDockOpacity: Double = 1
    static let dockOpacityKey = "sidebarDockOpacity"
    static let idleSidebarOpacity: CGFloat = 0.35
    static let idleBehaviorKey = "sidebarIdleBehavior"
    static let maximumShadowOpacity: Double = 5
    static let minimumSnapDistance: Double = 20
    static let maximumSnapDistance: Double = 460
    // One app-wide value, set in Window Layout preferences; not saved per display.
    static let snapDistanceKey = "sidebarSnapDistance"

    static func normalizedSnapDistance(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSnapDistance }
        return min(max(value, minimumSnapDistance), maximumSnapDistance)
    }

    static func snapDistance(in defaults: UserDefaults = .standard) -> Double {
        normalizedSnapDistance(defaults.object(forKey: snapDistanceKey) as? Double ?? defaultSnapDistance)
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
            // The single-window menu and window titles are left unregistered so an unset value
            // falls back to the saved style's default (see SidebarConfiguration.init(defaults:)).
            SidebarStyle.key: SidebarStyle.defaultStyle.rawValue,
            "sidebarAppSpacing": defaultAppSpacing,
            "sidebarFontSize": defaultFontSize,
            "sidebarShadowOpacity": defaultShadowOpacity,
            dockOpacityKey: defaultDockOpacity,
            snapDistanceKey: defaultSnapDistance,
            virtualNotchWidthKey: defaultVirtualNotchWidth,
            delayedOpeningKey: SidebarDelayedOpening.defaultChoice.rawValue,
            openingDelayKey: defaultOpeningDelay,
            closingDelayKey: defaultClosingDelay
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

    static func enableCompactIconsForConnectedDisplays(_ displays: [(id: String, name: String)],
                                                       in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: compactIconsKey)

        let preferences = displayPreferences(in: defaults)
        for display in displays {
            var displayConfiguration = preferences[display.id]?.configuration
                ?? SidebarConfiguration(defaults: defaults)
            displayConfiguration.compactShowsIcons = true
            save(displayConfiguration, for: display.id, name: display.name, in: defaults)
        }
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
    // Horizontal slots need less label space, while retaining the enlarged icon's width.
    static let notchItemWidth: CGFloat = 64
    static let compactWidth: CGFloat = 20
    static let notchTriggerHeight: CGFloat = 10
    static let virtualNotchWidthRatio: CGFloat = 0.13
    static let virtualNotchHeightRatio: CGFloat = 0.033
    static let virtualNotchWidthRange: ClosedRange<CGFloat> = 160...240
    static let virtualNotchHeightRange: ClosedRange<CGFloat> = 24...36
    static let notchBarMaximumScreenFraction: CGFloat = 0.72
    static let notchBarPadding: CGFloat = 8
    static let notchMonitorWidth: CGFloat = 40
    static let notchCloseDelay: TimeInterval = 0.25
    static let notchWindowMenuOffset: CGFloat = 40
    static let notchWindowMenuWidth: CGFloat = 220
    static let notchEmptyWidth: CGFloat = 40
    static let notchSeparatorWidth: CGFloat = 12
    // Extra canvas toward the desktop for the magnified frost's soft edges.
    static let drawingPadding: CGFloat = 36
    static let menuGap: CGFloat = 2
    // Keep the icon and title close together so the sidebar reads as a compact dock.
    static let rowHeight: CGFloat = 86
    // Without window titles, each row needs just the enlarged icon's height.
    static let iconOnlyRowHeight: CGFloat = 46
    static let dockBarWidth: CGFloat = 58
    // A titled Dock bar is wide enough to wrap titles like the Floating sidebar does.
    static let dockTitledBarWidth: CGFloat = 70
    static let badgeFontSize: CGFloat = 9
    static let badgeMinimumWidth: CGFloat = 15
    static let dockCornerRadius: CGFloat = 16
    // Keeps separator lines within the dock bar's rounded edges.
    static let dockSeparatorInset: CGFloat = 20
    static let desktopSeparatorHeight: CGFloat = 12
    // The Dock's line has no frost behind it, so it needs less room than the Floating separator.
    static let dockSeparatorHeight: CGFloat = 6
    // Space above and below a visible Dock display line, as a share of the app spacing.
    static let dockSeparatorGapRatio: CGFloat = 0.90
    // Moves gap from below each Dock line (display and Desktop) to above it: the icon below carries its own slot inset,
    // while the label above ends flush, so equal gaps look top-heavy. Total height is unchanged.
    static let dockSeparatorOpticalShift: CGFloat = 6
    // Fills more of the fixed icon slot, so row spacing is unchanged.
    static let iconSize: CGFloat = 44
    static let iconSlotHeight: CGFloat = 46
    static let labelHeight: CGFloat = 40
    static let titleVerticalPadding: CGFloat = 2
    // Vertical Dock titles move up into the icon slot's spare bottom margin, closer to their icon.
    static let dockTitleLift: CGFloat = 3
    static let titleLineLimit = 2

    // All title lines of the medium-weight title font, plus their padding above and below.
    static func titleHeight(fontSize: Double) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .medium)
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        return lineHeight * CGFloat(titleLineLimit) + titleVerticalPadding * 2
    }
    static let magnificationGrowth: CGFloat = 0.32
    /// Hover lift for the icons directly above and below the magnified one.
    static let neighborMagnificationGrowth: CGFloat = 0.04
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
                             contentHeight: CGFloat? = nil, minimumHeight: CGFloat = rowHeight,
                             itemHeight: CGFloat = rowHeight) -> CGRect {
        let separators = CGFloat(max(0, separatorCount)) * (desktopSeparatorHeight + appSpacing)
        let height = min(max(minimumHeight,
            contentHeight ?? (listContentHeight(count: count, appSpacing: appSpacing, itemHeight: itemHeight) + separators)),
            visibleFrame.height)
        let width = min(Self.width, visibleFrame.width)
        return CGRect(
            x: side == .left ? visibleFrame.minX : visibleFrame.maxX - width,
            y: visibleFrame.minY + (visibleFrame.height - height) * (1 - min(1, max(0, position))),
            width: width, height: height
        )
    }

    // Height of a plain list of rows with no Desktop or display headers.
    static func listContentHeight(count: Int, appSpacing: CGFloat, itemHeight: CGFloat = rowHeight) -> CGFloat {
        CGFloat(count) * itemHeight + CGFloat(max(0, count - 1)) * appSpacing + 16
    }

    static func compactContentHeight(count: Int, appSpacing: CGFloat, itemHeight: CGFloat = rowHeight) -> CGFloat {
        guard count > 0 else { return itemHeight }
        let numberSlots = CGFloat(count) * iconSlotHeight
        let gaps = CGFloat(count - 1) * (max(0, itemHeight - iconSlotHeight) + appSpacing)
        return numberSlots + gaps + verticalPadding * 2
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

    // The number strip stays at the display edge; the app column opens toward the desktop.
    static func compactFrames(beside frame: CGRect, side: SidebarSide, expanded: Bool,
                              stripWidth: CGFloat = compactWidth) -> (main: CGRect, compact: CGRect, panel: CGRect) {
        let compact = CGRect(x: side == .left ? frame.minX : frame.maxX - stripWidth,
                             y: frame.minY, width: stripWidth, height: frame.height)
        let main = frame.offsetBy(dx: side == .left ? stripWidth : -stripWidth, dy: 0)
        let drawing = CGRect(x: side == .left ? main.minX : main.minX - drawingPadding,
                             y: main.minY, width: main.width + drawingPadding, height: main.height)
        return (main, compact, expanded ? drawing.union(compact) : compact)
    }

    // A hardware notch gets a small extension; other Macs get a proportional top-centre notch.
    static func hardwareNotchFrame(screenFrame: CGRect, safeTopInset: CGFloat,
                                   leftArea: CGRect?, rightArea: CGRect?) -> CGRect? {
        guard safeTopInset.isFinite, safeTopInset > 0, let leftArea, let rightArea else { return nil }
        let minX = max(screenFrame.minX, leftArea.maxX)
        let maxX = min(screenFrame.maxX, rightArea.minX)
        let y = screenFrame.maxY - safeTopInset - notchTriggerHeight
        guard minX.isFinite, maxX.isFinite, y.isFinite, maxX > minX, y >= screenFrame.minY else { return nil }
        return CGRect(x: minX, y: y, width: maxX - minX, height: notchTriggerHeight)
    }

    // A pointer pushed against the top edge reports y == screen maxY, which half-open
    // CGRect hit tests treat as outside the notch and the Dock bar. Move it onto the top row,
    // unless a display stacked above actually owns that point.
    static func pointerHitPoint(_ point: CGPoint, screenFrame: CGRect, allScreenFrames: [CGRect]) -> CGPoint {
        guard point.y == screenFrame.maxY, point.x >= screenFrame.minX, point.x < screenFrame.maxX,
              !allScreenFrames.contains(where: { $0.contains(point) }) else { return point }
        return CGPoint(x: point.x, y: screenFrame.maxY - 0.5)
    }

    static func notchTriggerFrame(screenFrame: CGRect, safeTopInset: CGFloat,
                                  leftArea: CGRect?, rightArea: CGRect?, virtualWidth: CGFloat? = nil) -> CGRect? {
        guard screenFrame.width.isFinite, screenFrame.height.isFinite,
              screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        if let hardware = hardwareNotchFrame(screenFrame: screenFrame, safeTopInset: safeTopInset,
                                             leftArea: leftArea, rightArea: rightArea) {
            return hardware
        }
        let automaticWidth = min(max(screenFrame.width * virtualNotchWidthRatio,
                            virtualNotchWidthRange.lowerBound), virtualNotchWidthRange.upperBound)
        let requestedWidth = virtualWidth.flatMap { $0.isFinite ? $0 : nil } ?? automaticWidth
        let width = min(screenFrame.width, max(0, requestedWidth))
        let height = min(max(screenFrame.height * virtualNotchHeightRatio,
                             virtualNotchHeightRange.lowerBound), virtualNotchHeightRange.upperBound)
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height,
                      width: width, height: height)
    }

    // `topExtension` stretches the content up from the notch to the screen top, so the Dock bar
    // can start as the notch itself and widen from there.
    static func notchSidebarFrames(contentSize: CGSize, below notch: CGRect, availableFrame: CGRect,
                                   topExtension: CGFloat = 0) -> (content: CGRect, panel: CGRect) {
        let width = min(max(0, contentSize.width), availableFrame.width)
        let availableHeight = max(0, notch.minY - availableFrame.minY)
        let barHeight = min(max(0, contentSize.height), availableHeight)
        let height = barHeight + max(0, topExtension)
        let x = min(max(notch.midX - width / 2, availableFrame.minX), availableFrame.maxX - width)
        let content = CGRect(x: x, y: notch.minY - barHeight, width: width, height: height)
        let panelWidth = min(width + drawingPadding * 2, availableFrame.width)
        let panelX = min(max(content.midX - panelWidth / 2, availableFrame.minX),
                         availableFrame.maxX - panelWidth)
        // The enlarged title and its frost can draw below the row. Keep this canvas
        // separate from the content rectangle used for hover and drop targets.
        let bottomPadding = min(drawingPadding, max(0, content.minY - availableFrame.minY))
        return (content, CGRect(x: panelX, y: content.minY - bottomPadding,
                                width: panelWidth, height: height + bottomPadding))
    }

    static func notchBarSize(count: Int, appSpacing: CGFloat, availableFrame: CGRect,
                             groupedWidth: CGFloat? = nil, itemHeight: CGFloat = rowHeight) -> CGSize {
        let itemCount = max(1, count)
        let idealWidth = max(width, groupedWidth ?? (CGFloat(itemCount) * notchItemWidth
            + CGFloat(max(0, itemCount - 1)) * appSpacing)) + notchBarPadding * 2
        let maximumWidth = min(availableFrame.width,
            max(width + notchBarPadding * 2, availableFrame.width * notchBarMaximumScreenFraction))
        return CGSize(width: min(idealWidth, maximumWidth),
                      height: min(itemHeight + notchBarPadding * 2, availableFrame.height))
    }

    static func acceptsSidebarPointer(at point: CGPoint, sidebar: CGRect, menu: CGRect?) -> Bool {
        sidebar.contains(point) && !(menu?.contains(point) ?? false)
    }

    // Window lists sit immediately under the icon; desktop menus stay below the bar.
    static func notchMenuFrame(size: CGSize, icon: CGRect, bar: CGRect, screen: CGRect,
                               belowIcon: Bool = false) -> CGRect {
        let width = min(size.width, screen.width)
        let top = min(belowIcon ? icon.minY : bar.minY, screen.maxY)
        let height = min(size.height, max(0, top - screen.minY))
        let offset = belowIcon ? notchWindowMenuOffset : 0
        return CGRect(x: min(max(icon.midX - width / 2 + offset, screen.minX), screen.maxX - width),
                      y: top - height, width: width, height: height)
    }

    static func notchMenuBridge(menu: CGRect, anchor: CGRect) -> CGRect {
        guard menu.maxY <= anchor.minY else { return .zero }
        let left = max(menu.minX, anchor.minX)
        let right = min(menu.maxX, anchor.maxX)
        return CGRect(x: left, y: menu.maxY, width: max(0, right - left), height: anchor.minY - menu.maxY)
    }

    static func dragScrollDelta(at point: CGPoint, frame: CGRect, horizontal: Bool,
                                 flipped: Bool) -> CGPoint {
        guard frame.contains(point) else { return .zero }
        if horizontal {
            if point.x < frame.minX + 22 { return CGPoint(x: -10, y: 0) }
            if point.x > frame.maxX - 22 { return CGPoint(x: 10, y: 0) }
        } else {
            if point.y > frame.maxY - 22 { return CGPoint(x: 0, y: flipped ? -10 : 10) }
            if point.y < frame.minY + 22 { return CGPoint(x: 0, y: flipped ? 10 : -10) }
        }
        return .zero
    }
}
