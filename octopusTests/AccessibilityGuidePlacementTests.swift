import CoreGraphics
import Testing
@testable import octopus

struct AccessibilityGuidePlacementTests {
    private let panel = CGSize(width: 340, height: 150)
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 860)

    private func origin(for window: CGRect) -> CGPoint {
        AccessibilityGuidePlacement.origin(panelSize: panel, settingsWindow: window, visibleFrame: visible)
    }

    @Test func docksBelowWhenThereIsRoom() {
        let window = CGRect(x: 300, y: 300, width: 700, height: 500)
        #expect(origin(for: window) == CGPoint(x: 480, y: 142))
    }

    @Test func movesAboveThenBesideInsteadOfCoveringTheWindow() {
        let lowWindow = CGRect(x: 300, y: 20, width: 700, height: 500)
        #expect(origin(for: lowWindow) == CGPoint(x: 480, y: 528))

        let fullHeightWindow = CGRect(x: 100, y: 0, width: 700, height: 860)
        let beside = origin(for: fullHeightWindow)
        #expect(beside == CGPoint(x: 808, y: 8))
        #expect(!CGRect(origin: beside, size: panel).intersects(fullHeightWindow))
    }

    @Test func maximisedWindowFallsBackToItsBottomLeftCorner() {
        #expect(origin(for: visible) == CGPoint(x: 8, y: 8))
    }
}
