import Foundation

////////////////////
//// Numeric values for sidebar settings
/// Defaults and input ranges shared by settings controls and configuration normalization.
// Changing a default only affects users who never changed that setting; saved values are kept.

enum SidebarSettingsValues {
    // App spacing and title font
    static let defaultAppSpacing: Double = 4
    static let maximumAppSpacing: Double = 16
    static let defaultFontSize: Double = 10
    static let minimumFontSize: Double = 9
    static let maximumFontSize: Double = 15

    // Panel appearance
    static let defaultShadowOpacity: Double = 1
    static let maximumShadowOpacity: Double = 5
    static let defaultDockOpacity: Double = 1

    // Snap distance: one app-wide value, set in Window Layout preferences.
    static let defaultSnapDistance: Double = 200
    static let minimumSnapDistance: Double = 20
    static let maximumSnapDistance: Double = 460

    // Mac Notch bar on displays without a hardware notch
    static let defaultVirtualNotchWidth: Double = 200
    static let virtualNotchWidthRange: ClosedRange<Double> = 100...400

    // Delay opening: seconds, shared by the opening and closing delays.
    static let delayRange: ClosedRange<Double> = 0.1...5.0
    static let defaultOpeningDelay: Double = 0.5
    static let defaultClosingDelay: Double = 0.8
}

//// Keep every sidebar default and range here so controls and normalization agree.
//////////////////
