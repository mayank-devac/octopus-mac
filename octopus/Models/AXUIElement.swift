//
//  AXUIElement.swift
//  octopus
//
//

import Foundation
import Cocoa

// A successful bulk AX response can still contain optional absence or an error in a slot.
enum WindowAXAttributeValue {
    case value(AnyObject)
    case absent
    case unsupported
    case failed(AXError)

    init(_ object: AnyObject?) {
        guard let object, CFGetTypeID(object) != CFNullGetTypeID() else { self = .absent; return }
        if CFGetTypeID(object) == AXValueGetTypeID() {
            let value = unsafeBitCast(object, to: AXValue.self)
            if AXValueGetType(value) == .axError {
                var error = AXError.failure
                guard AXValueGetValue(value, .axError, &error) else { self = .failed(.failure); return }
                switch error {
                case .noValue: self = .absent
                case .attributeUnsupported, .notImplemented: self = .unsupported
                default: self = .failed(error)
                }
                return
            }
        }
        self = .value(object)
    }

    var object: AnyObject? { if case .value(let value) = self { return value }; return nil }
    var optionalAbsence: Bool {
        switch self { case .absent, .unsupported: return true; default: return false }
    }
    var needsIndividualFallback: Bool { if case .unsupported = self { return true }; return false }
    var optionalBool: Bool? { optionalAbsence ? false : object as? Bool }
}


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
        var fallback = result == .notImplemented || result == .attributeUnsupported
        if result == .success, let values = values as? [AnyObject], values.count == 2 {
            let slots = values.map { WindowAXAttributeValue($0) }
            // An unsupported slot permits fallback; a timeout or missing required value must stop the read.
            if slots.contains(where: {
                switch $0 { case .absent, .failed: return true; default: return false }
            }) { return nil }
            fallback = slots.contains { $0.needsIndividualFallback }
            if !fallback {
                guard let position = slots[0].object, let size = slots[1].object else { return nil }
                return Self.decodeWindowFrame(position: position, size: size)
            }
        }
        // A provider may implement individual attributes without implementing the bulk API.
        guard fallback else { return nil }
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
