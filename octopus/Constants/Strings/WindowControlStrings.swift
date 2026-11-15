import Foundation

////////////////////
//// User-facing text for the close / minimise / zoom traffic lights

enum WindowControlStrings {
    static func close(_ title: String) -> String { "Close \(title)" }
    static func minimize(_ title: String) -> String { "Minimise \(title)" }
    static func restore(_ title: String) -> String { "Restore \(title)" }
    static func zoom(_ title: String) -> String {
        "Fill screen with \(title) (double-click for full screen, ⌥-click to zoom)"
    }
}

//////////////////
