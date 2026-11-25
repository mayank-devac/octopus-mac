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
        //// Bounds at the caret
        /// The character just before the caret is measured first: apps report it far
        /// more reliably than a collapsed range, which some answer with the whole
        /// line, field or a stale rect. Its trailing edge is the caret.
        // AX uses top-left global coordinates, flipped here against the primary screen.

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection),
              let primary = NSScreen.screens.first else { return nil }

        let screens = NSScreen.screens.map(\.frame)
        if selection.length == 0, selection.location > 0,
           let previous = bounds(of: CFRange(location: selection.location - 1, length: 1), in: focused),
           let caret = plausibleCaret(CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height),
                                      primaryMaxY: primary.frame.maxY, screens: screens) {
            return caret
        }
        guard let collapsed = bounds(of: selection, in: focused) else { return nil }
        return plausibleCaret(collapsed, primaryMaxY: primary.frame.maxY, screens: screens)

        //// Anything taller than a text line or off every screen is not a caret.
        //////////////////
    }

    /// Tallest rect still treated as one line of text; taller means a field or paragraph.
    static let maxCaretHeight: CGFloat = 64

    /// Flips an AX rect to AppKit coordinates and keeps it only when it looks like a caret.
    static func plausibleCaret(_ axRect: CGRect, primaryMaxY: CGFloat, screens: [CGRect]) -> CGRect? {
        guard axRect.height > 0, axRect.height <= maxCaretHeight else { return nil }
        let rect = CGRect(x: axRect.minX, y: primaryMaxY - axRect.maxY, width: axRect.width, height: axRect.height)
        let probe = CGPoint(x: rect.minX, y: rect.midY)
        return screens.contains { $0.contains(probe) } ? rect : nil
    }

    @MainActor
    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds) else { return nil }
        return bounds
    }
}
