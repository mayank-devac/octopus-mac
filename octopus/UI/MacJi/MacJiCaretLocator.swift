//
//  MacJiCaretLocator.swift
//  octopus
//
//  Finds the text caret of the focused app through AX so the panel opens
//  under it. Many apps (Electron, some web views, terminals) do not report
//  text bounds; callers fall back to the pointer.
//

import AppKit

enum MacJiCaretLocator {
    /// Caret rectangle in AppKit screen coordinates, or nil when unavailable.
    @MainActor
    static func caretRect() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.1)

        ////////////////////
        //// Bounds of the selection
        /// A collapsed selection is the caret; some apps report a zero-width rect for it.
        // AX uses top-left global coordinates, flipped here against the primary screen.

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds), bounds.height > 0,
              let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)

        //// A zero-height rect means the app gave no usable caret position.
        //////////////////
    }
}
