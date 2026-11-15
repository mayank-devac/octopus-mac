import SwiftUI

////////////////////
//// Appear animation: fade in and grow out of the anchor side, settling with a slight wobble
/// The hosting view stays alive while its panel is hidden, so `onAppear` runs once.
/// A new `presentationID` restarts the animation for each new presentation;
// refreshes keep the same ID and never replay it.

struct MenuAppearModifier: ViewModifier {
    let presentationID: UUID
    /// The side the card grows from (the side facing its icon); nil grows from the centre.
    let edge: HorizontalEdge?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .scaleEffect(isShown || reduceMotion ? 1 : MenuMotion.appearScale, anchor: anchor)
            .onAppear(perform: replay)
            .onChange(of: presentationID) { replay() }
    }

    private var anchor: UnitPoint {
        switch edge {
        case .leading: return .leading
        case .trailing: return .trailing
        case nil: return .center
        }
    }

    private func replay() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { isShown = false }
        // Animate on the next turn so the reset frame is committed first.
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : MenuMotion.appear) { isShown = true }
        }
    }
}

//////////////////
