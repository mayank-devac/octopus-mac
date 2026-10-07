import AppKit
import ColorSync

enum SidebarSide: String, CaseIterable {
    case left, right
}

enum SidebarDesktopScope: String, CaseIterable {
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

enum SidebarSettings {
    static let defaultAppSpacing: Double = 4
    static let maximumAppSpacing: Double = 16
    static let defaultFontSize: Double = 11
    static let minimumFontSize: Double = 9
    static let maximumFontSize: Double = 15
    static let defaultSnapDistance: Double = 200
    static let defaultShadowOpacity: Double = 1
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

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "sidebarEnabled": true,
            "sidebarDesktopScope": SidebarDesktopScope.allDesktops.rawValue,
            "sidebarSide": SidebarSide.right.rawValue,
            "sidebarPosition": 0.5,
            "sidebarMonitor": "primary",
            "sidebarAutoHide": false,
            "sidebarShowSingleWindowMenu": true,
            "sidebarAppSpacing": defaultAppSpacing,
            "sidebarFontSize": defaultFontSize,
            "sidebarShadowOpacity": defaultShadowOpacity,
            "sidebarSnapDistance": defaultSnapDistance
        ])
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func monitorID(_ screen: NSScreen) -> String? {
        guard let displayID = displayID(screen),
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func selectedScreen() -> NSScreen? {
        let savedID = UserDefaults.standard.string(forKey: "sidebarMonitor") ?? "primary"
        // NSScreen.main follows keyboard focus; screens.first is the primary display.
        return NSScreen.screens.first(where: { monitorID($0) == savedID }) ?? NSScreen.screens.first
    }
}

enum SidebarLayout {
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
