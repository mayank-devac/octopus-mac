//
//  Bindings.swift
//  octopus
//
//

import Foundation

typealias Bindings = [ApplicationBinding?]

struct Workspace: Codable, Equatable {
    var name: String
    var bundleIdentifiers: [String]

    init(name: String, bundleIdentifiers: [String]) {
        self.name = name
        var seen = Set<String>()
        self.bundleIdentifiers = bundleIdentifiers.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Workspace" : trimmed
    }
}

enum ApplicationBinding: Codable, Equatable {
    case application(String)
    case workspace(Workspace)

    // Single-app bindings keep their original string representation on disk.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let identifier = try? container.decode(String.self) {
            self = .application(identifier)
        } else {
            let workspace = try container.decode(Workspace.self)
            self = .workspace(Workspace(name: workspace.name, bundleIdentifiers: workspace.bundleIdentifiers))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .application(let identifier): try container.encode(identifier)
        case .workspace(let workspace): try container.encode(workspace)
        }
    }
}
