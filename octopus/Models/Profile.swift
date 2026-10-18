//
//  Profile.swift
//  octopus
//
//  Created  on 18-09-2025.
//

import Foundation

struct Profile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var lastUsedAt: Date
    var profileNumber: Int?
    var numberOrder: String?
    var bindings: Bindings

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        lastUsedAt: Date = .now,
        profileNumber: Int? = nil,
        numberOrder: String? = nil,
        bindings: Bindings = Array(repeating: nil, count: 10)
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.profileNumber = profileNumber
        self.numberOrder = numberOrder
        self.bindings = Profile.normalizedBindings(bindings)
    }
}

extension Profile {
    static func normalizedBindings(_ bindings: Bindings) -> Bindings {
        if bindings.count == 10 { return bindings }
        if bindings.count > 10 { return Array(bindings.prefix(10)) }
        return bindings + Array(repeating: nil, count: 10 - bindings.count)
    }

    mutating func bind(bundleIdentifier: String, slot: Int) {
        guard (0...9).contains(slot) else { return }
        bindings = Profile.normalizedBindings(bindings)

        for index in bindings.indices {
            if bindings[index] == .application(bundleIdentifier) {
                bindings[index] = nil
            }
        }

        bindings[slot] = .application(bundleIdentifier)
    }

    mutating func bind(bundleIdentifiers: [String], slot: Int) {
        guard (0...9).contains(slot) else { return }
        let workspace = Workspace(name: name,
                                  bundleIdentifiers: bundleIdentifiers)
        guard !workspace.bundleIdentifiers.isEmpty else { return }
        if workspace.bundleIdentifiers.count == 1, self.workspace(for: slot) == nil {
            bind(bundleIdentifier: workspace.bundleIdentifiers[0], slot: slot)
        } else {
            bindings = Profile.normalizedBindings(bindings)
            bindings[slot] = .workspace(workspace)
        }
    }

    mutating func addApplications(bundleIdentifiers: [String], slot: Int) {
        guard (0...9).contains(slot), !bundleIdentifiers.isEmpty else { return }
        let existing: [String]
        switch binding(for: slot) {
        case .application(let identifier): existing = [identifier]
        case .workspace(let workspace): existing = workspace.bundleIdentifiers
        case nil: existing = []
        }
        bind(bundleIdentifiers: existing + bundleIdentifiers, slot: slot)
    }

    mutating func unbind(slot: Int) {
        guard (0...9).contains(slot) else { return }
        bindings = Profile.normalizedBindings(bindings)
        bindings[slot] = nil
    }

    mutating func removeApplication(_ identifier: String, slot: Int) {
        guard let workspace = workspace(for: slot) else { return }
        let remaining = workspace.bundleIdentifiers.filter { $0 != identifier }
        if remaining.isEmpty {
            unbind(slot: slot)
        } else {
            bind(bundleIdentifiers: remaining, slot: slot)
        }
    }

    func bundleIdentifier(for slot: Int) -> String? {
        guard case .application(let identifier) = binding(for: slot) else { return nil }
        return identifier
    }

    func binding(for slot: Int) -> ApplicationBinding? {
        guard (0...9).contains(slot) else { return nil }
        return Profile.normalizedBindings(bindings)[slot]
    }

    func workspace(for slot: Int) -> Workspace? {
        guard case .workspace(var workspace) = binding(for: slot) else { return nil }
        workspace.name = name
        return workspace
    }

    var workspaceDefinition: Workspace {
        let identifiers = bindings.flatMap { binding -> [String] in
            switch binding {
            case .application(let identifier): return [identifier]
            case .workspace(let workspace): return workspace.bundleIdentifiers
            case nil: return []
            }
        }
        return Workspace(name: name, bundleIdentifiers: identifiers)
    }

    // Move the old binding-level default name to the entry in the left panel.
    mutating func migrateWorkspaceName() {
        guard name == "Default" || name == "New Profile" else { return }
        for binding in bindings {
            if case .workspace(let workspace) = binding {
                name = workspace.displayName
                return
            }
        }
    }
}
