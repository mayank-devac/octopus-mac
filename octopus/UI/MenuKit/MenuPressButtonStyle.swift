import SwiftUI

////////////////////
//// Button style for menu cells: shrink while pressed, no system bezel
/// Highlight colours come from the pointer path, not from SwiftUI hover.

struct MenuPressButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = MenuMotion.pressedScale

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, pressedScale: pressedScale)
    }

    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        let pressedScale: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
                .animation(MenuMotion.press, value: configuration.isPressed)
        }
    }
}

//////////////////
