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

    static func saved(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .compact
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
    var compactShowsIcons: Bool
    var showSingleWindowMenu: Bool
    var appSpacing: Double
    var fontSize: Double
    var shadowOpacity: Double
    var snapDistance: Double
    var virtualNotchWidth: Double

    init(defaults: UserDefaults? = .standard) {
        enabled = defaults?.object(forKey: "sidebarEnabled") as? Bool ?? true
        desktopScope = .saved(defaults?.string(forKey: "sidebarDesktopScope"))
        displayScope = .saved(defaults?.string(forKey: "sidebarDisplayScope"))
        side = SidebarSide(rawValue: defaults?.string(forKey: "sidebarSide") ?? "") ?? .right
        position = defaults?.object(forKey: "sidebarPosition") as? Double ?? 0.5
        idleBehavior = .saved(defaults?.string(forKey: SidebarSettings.idleBehaviorKey))
        compactShowsIcons = defaults?.bool(forKey: SidebarSettings.compactIconsKey) ?? false
        showSingleWindowMenu = defaults?.object(forKey: "sidebarShowSingleWindowMenu") as? Bool ?? true
        appSpacing = defaults?.object(forKey: "sidebarAppSpacing") as? Double ?? SidebarSettings.defaultAppSpacing
        fontSize = defaults?.object(forKey: "sidebarFontSize") as? Double ?? SidebarSettings.defaultFontSize
        shadowOpacity = defaults?.object(forKey: "sidebarShadowOpacity") as? Double ?? SidebarSettings.defaultShadowOpacity
        snapDistance = defaults.map { SidebarSettings.snapDistance(in: $0) } ?? SidebarSettings.defaultSnapDistance
        virtualNotchWidth = defaults?.object(forKey: SidebarSettings.virtualNotchWidthKey) as? Double
            ?? SidebarSettings.defaultVirtualNotchWidth
        normalize()
    }

    // Passing no preference store uses the same fallbacks as a fresh installation.
    static var factoryDefaults: Self { Self(defaults: nil) }

    private enum CodingKeys: String, CodingKey {
        case enabled, desktopScope, displayScope, side, position, idleBehavior, compactShowsIcons
        case showSingleWindowMenu, appSpacing, fontSize, shadowOpacity, snapDistance, virtualNotchWidth
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
        compactShowsIcons = try saved.decodeIfPresent(Bool.self, forKey: .compactShowsIcons) ?? false
        showSingleWindowMenu = try saved.decodeIfPresent(Bool.self, forKey: .showSingleWindowMenu) ?? showSingleWindowMenu
        appSpacing = try saved.decodeIfPresent(Double.self, forKey: .appSpacing) ?? appSpacing
        fontSize = try saved.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        shadowOpacity = try saved.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? shadowOpacity
        snapDistance = try saved.decodeIfPresent(Double.self, forKey: .snapDistance) ?? snapDistance
        virtualNotchWidth = try saved.decodeIfPresent(Double.self, forKey: .virtualNotchWidth) ?? virtualNotchWidth
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
        virtualNotchWidth = clamp(virtualNotchWidth, SidebarSettings.virtualNotchWidthRange,
                                 fallback: SidebarSettings.defaultVirtualNotchWidth)
    }

    func saveSingleSidebar(in defaults: UserDefaults = .standard) {
        let values: [String: Any] = [
            "sidebarEnabled": enabled, "sidebarDesktopScope": desktopScope.rawValue,
            "sidebarDisplayScope": displayScope.rawValue,
            "sidebarSide": side.rawValue, "sidebarPosition": position,
            SidebarSettings.idleBehaviorKey: idleBehavior.rawValue,
            SidebarSettings.compactIconsKey: compactShowsIcons,
            "sidebarShowSingleWindowMenu": showSingleWindowMenu, "sidebarAppSpacing": appSpacing,
            "sidebarFontSize": fontSize, "sidebarShadowOpacity": shadowOpacity,
            "sidebarSnapDistance": snapDistance,
            SidebarSettings.virtualNotchWidthKey: virtualNotchWidth
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
    static let compactIconsKey = "sidebarCompactShowsIcons"
    static let virtualNotchWidthKey = "sidebarVirtualNotchWidth"
    static let defaultVirtualNotchWidth: Double = 200
    static let virtualNotchWidthRange: ClosedRange<Double> = 100...400
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
            "sidebarSnapDistance": defaultSnapDistance,
            virtualNotchWidthKey: defaultVirtualNotchWidth
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
    static let notchBarPadding: CGFloat = 4
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
                             contentHeight: CGFloat? = nil, minimumHeight: CGFloat = rowHeight) -> CGRect {
        let gaps = CGFloat(max(0, count - 1)) * appSpacing
        let separators = CGFloat(max(0, separatorCount)) * (desktopSeparatorHeight + appSpacing)
        let height = min(max(minimumHeight,
            contentHeight ?? (CGFloat(count) * rowHeight + gaps + separators + 16)), visibleFrame.height)
        let width = min(Self.width, visibleFrame.width)
        return CGRect(
            x: side == .left ? visibleFrame.minX : visibleFrame.maxX - width,
            y: visibleFrame.minY + (visibleFrame.height - height) * (1 - min(1, max(0, position))),
            width: width, height: height
        )
    }

    static func compactContentHeight(count: Int, appSpacing: CGFloat) -> CGFloat {
        guard count > 0 else { return rowHeight }
        let numberSlots = CGFloat(count) * iconSlotHeight
        let gaps = CGFloat(count - 1) * (labelHeight + appSpacing)
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
    static func compactFrames(beside frame: CGRect, side: SidebarSide,
                              expanded: Bool) -> (main: CGRect, compact: CGRect, panel: CGRect) {
        let compact = CGRect(x: side == .left ? frame.minX : frame.maxX - compactWidth,
                             y: frame.minY, width: compactWidth, height: frame.height)
        let main = frame.offsetBy(dx: side == .left ? compactWidth : -compactWidth, dy: 0)
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

    static func notchSidebarFrames(contentSize: CGSize, below notch: CGRect,
                                   availableFrame: CGRect) -> (content: CGRect, panel: CGRect) {
        let width = min(max(0, contentSize.width), availableFrame.width)
        let availableHeight = max(0, notch.minY - availableFrame.minY)
        let height = min(max(0, contentSize.height), availableHeight)
        let x = min(max(notch.midX - width / 2, availableFrame.minX), availableFrame.maxX - width)
        let content = CGRect(x: x, y: notch.minY - height, width: width, height: height)
        let panelWidth = min(width + drawingPadding * 2, availableFrame.width)
        let panelX = min(max(content.midX - panelWidth / 2, availableFrame.minX),
                         availableFrame.maxX - panelWidth)
        // The enlarged title and its frost can draw below the row. Keep this canvas
        // separate from the content rectangle used for hover and drop targets.
        let bottomPadding = min(drawingPadding, max(0, content.minY - availableFrame.minY))
        return (content, CGRect(x: panelX, y: content.minY - bottomPadding,
                                width: panelWidth, height: height + bottomPadding))
    }

    static func notchBarSize(count: Int, appSpacing: CGFloat,
                             availableFrame: CGRect, groupedWidth: CGFloat? = nil) -> CGSize {
        let itemCount = max(1, count)
        let idealWidth = max(width, groupedWidth ?? (CGFloat(itemCount) * notchItemWidth
            + CGFloat(max(0, itemCount - 1)) * appSpacing)) + notchBarPadding * 2
        let maximumWidth = min(availableFrame.width,
            max(width + notchBarPadding * 2, availableFrame.width * notchBarMaximumScreenFraction))
        return CGSize(width: min(idealWidth, maximumWidth),
                      height: min(rowHeight + notchBarPadding * 2, availableFrame.height))
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
