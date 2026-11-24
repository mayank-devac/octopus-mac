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
    case hideEdge = "hideUntilEdge"

    static let defaultChoice: Self = .hideEdge

    static func saved(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? defaultChoice
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .stepAside: return "Step aside"
        case .hideEdge: return "Hide edge"
        }
    }

    // Preferences copy for the delay slider; Off has no delay to set.
    var delayCopy: (title: String, help: String)? {
        switch self {
        case .off: return nil
        case .stepAside: return ("Closing delay", "How long the pointer must rest on the sidebar before it steps aside.")
        case .hideEdge: return ("Opening delay", "How long the pointer must rest at the edge before the sidebar opens.")
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
    // Seconds the pointer must rest at the edge before Hide edge opens the sidebar.
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
        appSpacing = defaults?.object(forKey: "sidebarAppSpacing") as? Double ?? SidebarSettingsValues.defaultAppSpacing
        fontSize = defaults?.object(forKey: "sidebarFontSize") as? Double ?? SidebarSettingsValues.defaultFontSize
        shadowOpacity = defaults?.object(forKey: "sidebarShadowOpacity") as? Double ?? SidebarSettingsValues.defaultShadowOpacity
        dockOpacity = defaults?.object(forKey: SidebarSettings.dockOpacityKey) as? Double ?? SidebarSettingsValues.defaultDockOpacity
        virtualNotchWidth = defaults?.object(forKey: SidebarSettings.virtualNotchWidthKey) as? Double
            ?? SidebarSettingsValues.defaultVirtualNotchWidth
        delayedOpening = .saved(defaults?.string(forKey: SidebarSettings.delayedOpeningKey))
        openingDelay = defaults?.object(forKey: SidebarSettings.openingDelayKey) as? Double
            ?? SidebarSettingsValues.defaultOpeningDelay
        closingDelay = defaults?.object(forKey: SidebarSettings.closingDelayKey) as? Double
            ?? SidebarSettingsValues.defaultClosingDelay
        normalize()
    }

    // The Delay opening choice in effect; Off when it is unavailable for the visibility mode.
    var activeDelayedOpening: SidebarDelayedOpening {
        idleBehavior.delayedOpeningChoices.contains(delayedOpening) ? delayedOpening : .off
    }

    // Hide edge is Auto-Hide with a reveal delay, so the view and `SidebarPresentation`
    // both draw from this instead of handling it as another mode.
    var effectiveIdleBehavior: SidebarIdleBehavior {
        activeDelayedOpening == .hideEdge ? .hide : idleBehavior
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
        appSpacing = clamp(appSpacing, 0...SidebarSettingsValues.maximumAppSpacing, fallback: SidebarSettingsValues.defaultAppSpacing)
        fontSize = clamp(fontSize, SidebarSettingsValues.minimumFontSize...SidebarSettingsValues.maximumFontSize,
                         fallback: SidebarSettingsValues.defaultFontSize)
        shadowOpacity = clamp(shadowOpacity, 0...SidebarSettingsValues.maximumShadowOpacity,
                              fallback: SidebarSettingsValues.defaultShadowOpacity)
        dockOpacity = clamp(dockOpacity, 0...1, fallback: SidebarSettingsValues.defaultDockOpacity)
        virtualNotchWidth = clamp(virtualNotchWidth, SidebarSettingsValues.virtualNotchWidthRange,
                                 fallback: SidebarSettingsValues.defaultVirtualNotchWidth)
        openingDelay = clamp(openingDelay, SidebarSettingsValues.delayRange,
                             fallback: SidebarSettingsValues.defaultOpeningDelay)
        closingDelay = clamp(closingDelay, SidebarSettingsValues.delayRange,
                             fallback: SidebarSettingsValues.defaultClosingDelay)
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
    ////////////////////
    //// UserDefaults keys
    /// Stored as plain strings: renaming one drops the user's saved value unless
    /// `SidebarSettingsMigrations.swift` carries it over. Numeric defaults live in `SidebarSettingsValues`.

    static let compactIconsKey = "sidebarCompactShowsIcons"
    static let edgeMarkKey = "sidebarAutoHideEdgeMark"
    static let edgeMarkColorKey = "sidebarAutoHideEdgeMarkColor"
    static let singleWindowMenuKey = "sidebarShowSingleWindowMenu"
    static let windowTitlesKey = "sidebarShowWindowTitles"
    static let inactiveStyleChoicesKey = "sidebarInactiveStyleChoices"
    static let virtualNotchWidthKey = "sidebarVirtualNotchWidth"
    static let delayedOpeningKey = "sidebarDelayedOpening"
    static let openingDelayKey = "sidebarOpeningDelay"
    static let closingDelayKey = "sidebarClosingDelay"
    static let multiDisplayKey = "sidebarMultiDisplayEnabled"
    static let displayPreferencesKey = "sidebarDisplayPreferences"
    // Display last chosen in the Settings "Display" picker, so reopening Settings shows the same monitor.
    static let settingsSelectedDisplayKey = "sidebarSettingsSelectedDisplay"
    static let dockOpacityKey = "sidebarDockOpacity"
    static let idleBehaviorKey = "sidebarIdleBehavior"
    // One app-wide value, set in Window Layout preferences; not saved per display.
    static let snapDistanceKey = "sidebarSnapDistance"

    //// Keys above are part of every user's saved preferences.
    //////////////////

    static let idleSidebarOpacity: CGFloat = 0.35

    static func normalizedSnapDistance(_ value: Double) -> Double {
        guard value.isFinite else { return SidebarSettingsValues.defaultSnapDistance }
        return min(max(value, SidebarSettingsValues.minimumSnapDistance), SidebarSettingsValues.maximumSnapDistance)
    }

    static func snapDistance(in defaults: UserDefaults = .standard) -> Double {
        normalizedSnapDistance(defaults.object(forKey: snapDistanceKey) as? Double ?? SidebarSettingsValues.defaultSnapDistance)
    }

    // Migrations run before `register(defaults:)` so they only see values the user actually saved.
    static func registerDefaults() {
        migrateLegacyAutoHide()
        migrateLegacyDisplaySnapDistance()
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
            "sidebarAppSpacing": SidebarSettingsValues.defaultAppSpacing,
            "sidebarFontSize": SidebarSettingsValues.defaultFontSize,
            "sidebarShadowOpacity": SidebarSettingsValues.defaultShadowOpacity,
            dockOpacityKey: SidebarSettingsValues.defaultDockOpacity,
            snapDistanceKey: SidebarSettingsValues.defaultSnapDistance,
            virtualNotchWidthKey: SidebarSettingsValues.defaultVirtualNotchWidth,
            delayedOpeningKey: SidebarDelayedOpening.defaultChoice.rawValue,
            openingDelayKey: SidebarSettingsValues.defaultOpeningDelay,
            closingDelayKey: SidebarSettingsValues.defaultClosingDelay
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
