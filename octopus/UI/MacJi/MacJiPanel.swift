//
//  MacJiPanel.swift
//  octopus
//
//  The floating, non-activating panel that hosts `MacJiView`, and where it
//  opens. It never becomes key, so typing keeps going to the app underneath.
//

import AppKit
import SwiftUI

final class MacJiPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    convenience init(rootView: some View) {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: rootView)
    }
}

////////////////////
//// Panel placement
/// The card opens just under the caret, left-aligned with it, and flips above
/// when there is no room below. Without a caret it opens at the pointer.
// Frames are AppKit screen coordinates and include the shadow margin.

enum MacJiPanelPlacement {
    static let caretGap: CGFloat = 4

    static func frame(card: CGSize, caret: CGRect?, pointer: CGPoint, visibleFrames: [CGRect]) -> CGRect {
        let anchor = caret ?? CGRect(origin: pointer, size: .zero)
        let margin = MenuShadowMargin.size
        let size = MenuShadowMargin.panelSize(card: card, facing: nil)
        let screen = visibleFrames.first { $0.contains(CGPoint(x: anchor.minX, y: anchor.midY)) }
            ?? visibleFrames.first ?? CGRect(origin: .zero, size: size)
        var origin = CGPoint(x: anchor.minX - margin, y: anchor.minY - caretGap - card.height - margin)
        if origin.y + margin < screen.minY {
            origin.y = anchor.maxY + caretGap - margin
        }
        origin.x = min(max(origin.x, screen.minX - margin), screen.maxX - size.width + margin)
        origin.y = min(max(origin.y, screen.minY - margin), screen.maxY - size.height + margin)
        return CGRect(origin: origin, size: size)
    }
}

//// The margin may hang off-screen; only the card itself is kept inside.
//////////////////
