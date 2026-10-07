//
//  CyclePanelState.swift
//  octopus
//
//

import Foundation
import AppKit

enum CyclePanelAction: Hashable {
    case launchApp
    case openWindow
    
    var title: String {
        switch self {
        case .launchApp:
            return "Launch app"
        case .openWindow:
            return "Focus app"
        }
    }
}

enum CyclePanelItem: Identifiable {
    case window(Window)
    case action(CyclePanelAction)

    enum ID: Hashable {
        case window(CGWindowID)
        case instance(ObjectIdentifier)
        case action(CyclePanelAction)
    }

    var id: ID {
        switch self {
        case .window(let window):
            if let id = window.cgWindowID, id != kCGNullWindowID { return .window(id) }
            return .instance(ObjectIdentifier(window))
        case .action(let action): return .action(action)
        }
    }

    var title: String {
        switch self {
        case .window(let window): return window.title
        case .action(let action): return action.title
        }
    }
}

enum SidebarPointerTarget: Equatable {
    case row(CyclePanelItem.ID)
    case windowAction(CyclePanelItem.ID)
    case hideApp
    case quitApp

    var itemID: CyclePanelItem.ID? {
        switch self {
        case .row(let id), .windowAction(let id): return id
        case .hideApp, .quitApp: return nil
        }
    }
}

@MainActor
final class CyclePanelState: ObservableObject {
    @Published var applicationTitle: String = ""
    @Published var items: [CyclePanelItem] = []
    @Published var selectedIndex: Int = 0
    @Published var showsHeader = true
    @Published private(set) var showsSidebarActions = false
    @Published private(set) var sidebarWindowStates: [CGWindowID: SidebarWindowState] = [:]
    @Published private(set) var sidebarAppIsHidden = false
    @Published private(set) var sidebarPointerTarget: SidebarPointerTarget?
    private(set) var shouldScrollToSelection = true
    
    var windows: [Window] {
        items.compactMap { item in
            if case let .window(window) = item {
                return window
            }
            
            return nil
        }
    }
    
    var currentItem: CyclePanelItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }
    
    var currentWindow: Window? {
        guard let currentItem else { return nil }
        
        if case let .window(window) = currentItem {
            return window
        }
        
        return nil
    }
    
    var currentAction: CyclePanelAction? {
        guard let currentItem else { return nil }
        
        if case let .action(action) = currentItem {
            return action
        }
        
        return nil
    }
    
    func setApplication(_ application: Application) {
        sidebarPointerTarget = nil
        showsSidebarActions = false
        sidebarWindowStates = [:]
        sidebarAppIsHidden = false
        shouldScrollToSelection = true
        showsHeader = true
        self.applicationTitle = application.title
        
        let windows = application.getWindows()
        if windows.isEmpty {
            let action: CyclePanelAction = application.isRunning ? .openWindow : .launchApp
            self.items = [.action(action)]
        } else {
            self.items = windows.map(CyclePanelItem.window)
        }
        
        self.selectedIndex = 0
    }
    
    func cycleNext() {
        guard !items.isEmpty else { return }
        shouldScrollToSelection = true
        selectedIndex = (selectedIndex + 1) % items.count
    }

    func setWindows(_ windows: [Window], applicationTitle: String, selectedID: CGWindowID?,
                    preserveInteraction: Bool = false,
                    sidebarWindowStates: [CGWindowID: SidebarWindowState]? = nil,
                    sidebarAppIsHidden: Bool = false) {
        let showActions = sidebarWindowStates != nil
        if showsSidebarActions != showActions { showsSidebarActions = showActions }
        let updatedStates = sidebarWindowStates ?? [:]
        if self.sidebarWindowStates != updatedStates {
            self.sidebarWindowStates = updatedStates
        }
        let hidden = showActions && sidebarAppIsHidden
        if self.sidebarAppIsHidden != hidden { self.sidebarAppIsHidden = hidden }
        var seenIDs = Set<CyclePanelItem.ID>()
        var updatedItems = windows.map(CyclePanelItem.window).filter { seenIDs.insert($0.id).inserted }
        if preserveInteraction {
            // Retain surviving rows in their current order; append newly opened windows.
            let incoming = Dictionary(uniqueKeysWithValues: updatedItems.map { ($0.id, $0) })
            let existingIDs = Set(items.map(\.id))
            updatedItems = items.compactMap { incoming[$0.id] }
                + updatedItems.filter { !existingIDs.contains($0.id) }
        }
        let updatedIndex = updatedItems.firstIndex { item in
            guard case .window(let window) = item, let selectedID else { return false }
            return window.cgWindowID == selectedID
        } ?? (preserveInteraction ? min(selectedIndex, max(0, updatedItems.count - 1)) : 0)
        shouldScrollToSelection = !preserveInteraction
        if showsHeader { showsHeader = false }
        if self.applicationTitle != applicationTitle { self.applicationTitle = applicationTitle }
        // An unrelated app's update must not rebuild these rows or reset their hover state.
        let unchanged = items.count == updatedItems.count && zip(items, updatedItems).allSatisfy {
            $0.0.id == $0.1.id && $0.0.title == $0.1.title
        }
        if !unchanged { items = updatedItems }
        if !preserveInteraction || !showActions
            || sidebarPointerTarget?.itemID.map({ id in !updatedItems.contains { $0.id == id } }) == true {
            sidebarPointerTarget = nil
        }
        if selectedIndex != updatedIndex { selectedIndex = updatedIndex }
    }

    func cyclePrevious() {
        guard !items.isEmpty else { return }
        shouldScrollToSelection = true
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
    }

    func selectFromPointer(_ index: Int) {
        guard items.indices.contains(index) else { return }
        // Hovering a row must not scroll it away from the pointer.
        shouldScrollToSelection = false
        if selectedIndex != index { selectedIndex = index }
    }

    func setSidebarPointerTarget(_ target: SidebarPointerTarget?) {
        guard showsSidebarActions else { return }
        if sidebarPointerTarget != target { sidebarPointerTarget = target }
        if let id = target?.itemID, let index = items.firstIndex(where: { $0.id == id }) {
            selectFromPointer(index)
        }
    }
    
    func reset() {
        sidebarPointerTarget = nil
        showsSidebarActions = false
        sidebarWindowStates = [:]
        sidebarAppIsHidden = false
        items = []
        selectedIndex = 0
        showsHeader = true
        applicationTitle = ""
    }
}
