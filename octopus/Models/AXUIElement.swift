//
//  AXUIElement.swift
//  octopus
//
//

import Foundation
import Cocoa


// Adds Swift wrappers around the accessibility object class.
extension AXUIElement {
    func getAttributeValue<T>(_ attribute: NSAccessibility.Attribute) -> T? {
        var value: AnyObject?
        
        let result = AXUIElementCopyAttributeValue(self, attribute.rawValue as CFString, &value)
        
        guard result == .success else {
            return nil
        }
        
        return value as? T
    }
    
    func performAction(_ action: NSAccessibility.Action) throws(AXError) {
        let result = AXUIElementPerformAction(self, action.rawValue as CFString)
        
        guard result == .success else {
            throw result
        }
    }
    
    func getWindowID() -> CGWindowID? {
        var windowID = CGWindowID(0)
        
        let result = _AXUIElementGetWindow(self, &windowID)
        
        guard result == .success else {
            return nil
        }
        
        return windowID
    }

    func getWindowFrame() -> CGRect? {
        // One IPC avoids paying two messaging round trips for every settle/readback pass.
        var values: CFArray?
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        let result = AXUIElementCopyMultipleAttributeValues(self, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        if result == .success, let values = values as? [AnyObject], values.count == 2 {
            return Self.decodeWindowFrame(position: values[0], size: values[1])
        }
        // A provider may implement individual attributes without implementing the bulk API.
        guard result == .notImplemented || result == .attributeUnsupported else { return nil }
        var positionObject: AnyObject?
        var sizeObject: AnyObject?
        guard AXUIElementCopyAttributeValue(self, NSAccessibility.Attribute.position.rawValue as CFString, &positionObject) == .success,
              AXUIElementCopyAttributeValue(self, NSAccessibility.Attribute.size.rawValue as CFString, &sizeObject) == .success,
              let positionObject,
              let sizeObject else { return nil }
        return Self.decodeWindowFrame(position: positionObject, size: sizeObject)
    }

    static func decodeWindowFrame(position: AnyObject, size: AnyObject) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let position = unsafeBitCast(position, to: AXValue.self)
        let size = unsafeBitCast(size, to: AXValue.self)

        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
              AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions),
              origin.x.isFinite, origin.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
    
    func test() -> Int? {
        return self.getAttributeValue(.identifier)
    }
}


// Make AXError conform to Error protocol
extension AXError: @retroactive _BridgedNSError {}
extension AXError: @retroactive _ObjectiveCBridgeableError {}
extension AXError: @retroactive Error {}


// Private Core Accessibility API
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError
