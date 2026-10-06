//
//  Window.swift
//  octopus
//
//  Created  on 12-09-2025.
//

import Foundation
import Cocoa


class Window: Identifiable {
    var id: CGWindowID { cgWindowID ?? 0 }
    var element: AXUIElement
    var cgWindowID: CGWindowID?
    var application: Application
    private var cachedTitle: String?

    init(_ element: AXUIElement, _ application: Application, cachedTitle: String? = nil) {
        self.element = element
        self.cgWindowID = element.getWindowID()
        self.application = application
        self.cachedTitle = cachedTitle
    }
    
    var title: String {
        if let cachedTitle { return cachedTitle }
        if let title: String = self.element.getAttributeValue(.title) {
            return title
        }
        
        return application.title
    }
    
    func focus() {
        do {
            try self.element.performAction(.raise)
            self.application.activate()
        } catch {
            try? self.application.reopen()
        }
    }
    
    static func getFrontWindow() -> Window? {
        guard let frontApplication = Application.getFrontApplication() else {
            return nil
        }
        
        if let focusedWindow = frontApplication.getFocusedWindow() {
            return focusedWindow
        }
        
        if let firstWindow = frontApplication.getFirstWindow() {
            return firstWindow
        }
        
        return nil
    }
}
