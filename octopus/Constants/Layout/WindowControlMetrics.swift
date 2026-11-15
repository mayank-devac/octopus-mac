import CoreGraphics

////////////////////
//// Sizes for the close / minimise / zoom traffic lights on window rows
/// Close to a real title bar's buttons so they read as the same controls.

enum WindowControlMetrics {
    static let diameter: CGFloat = 12
    static let spacing: CGFloat = 7
    static let symbolSize: CGFloat = 7
    static let horizontalPadding: CGFloat = 8

    /// Width reserved on a row so titles never run under the buttons.
    static var groupWidth: CGFloat {
        let count = CGFloat(WindowControl.allCases.count)
        return count * diameter + (count - 1) * spacing + 2 * horizontalPadding
    }
}

//////////////////
