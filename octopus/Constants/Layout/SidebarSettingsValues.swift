import Foundation

////////////////////
//// Numeric values for sidebar settings
/// Defaults and input ranges shared by settings controls and configuration normalization.

enum SidebarSettingsValues {
    static let defaultVirtualNotchWidth: Double = 200
    static let virtualNotchWidthRange: ClosedRange<Double> = 100...400
    static let openingDelayRange: ClosedRange<Double> = 0.1...5.0
    static let defaultOpeningDelay: Double = 0.5
    static let defaultClosingDelay: Double = 0.8
}

//////////////////
