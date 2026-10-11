//
//  CyclePanel.swift
//  octopus
//
//  Created  on 19-01-2026.
//

import AppKit
import SwiftUI


final class CyclePanel: NSPanel, NSWindowDelegate {
    var onResignKey: (() -> Void)?
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior.insert(.fullScreenAuxiliary)
        self.collectionBehavior.insert(.canJoinAllSpaces)
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovable = false
        self.animationBehavior = .none
        self.isMovableByWindowBackground = false
        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.delegate = self
        self.backgroundColor = .clear
        self.hidesOnDeactivate = true
        
        let effectView = NSVisualEffectView(frame: .zero)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active

        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true

        // Mask the native backdrop as well as the content layer. Layer rounding
        // alone can leave rectangular material/shadow outside the visible corners.
        let radius: CGFloat = 12
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1),
                           flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        effectView.maskImage = mask

        // Inherit system appearance so the existing blur adapts to Light and Dark mode.
        self.contentView = effectView
    }
    
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
    
    func windowDidResignKey(_ notification: Notification) {
        onResignKey?()
    }
}
