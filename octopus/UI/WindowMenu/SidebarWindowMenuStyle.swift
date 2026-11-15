import Foundation

////////////////////
//// Which window menu opens beside a hovered sidebar icon
/// Modern (default) is the shared workspace window menu; Classic is the
// original single-app window list.
// Modern lives in UI/WindowMenu/ (WindowMenuView, WindowMenuCatalogue, WindowMenuWindowList); 
// Classic lives in UI/CyclePanel/ (CyclePanelView, CyclePanelController, CyclePanel).

enum SidebarWindowMenuStyle: String, CaseIterable {
    case modern, classic

    static let defaultStyle: Self = .modern

    var title: String {
        switch self {
        case .modern: return WindowMenuStrings.styleModern
        case .classic: return WindowMenuStrings.styleClassic
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: PreferenceKeys.sidebarWindowMenuStyle).flatMap(Self.init(rawValue:)) ?? defaultStyle
    }
}

//////////////////
