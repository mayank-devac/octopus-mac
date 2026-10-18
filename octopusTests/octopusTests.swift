//
//  octopusTests.swift
//  octopusTests
//
//  Created  on 12-09-2025.
//

import Foundation
import Testing
@testable import octopus

struct WorkspaceTests {

    @Test func appsCanBeAddedOneAtATimeWithoutReplacingEarlierChoices() {
        var profile = Profile(name: "Work")
        profile.addApplications(bundleIdentifiers: ["com.apple.Safari"], slot: 1)
        #expect(profile.bundleIdentifier(for: 1) == "com.apple.Safari")
        profile.addApplications(bundleIdentifiers: ["com.apple.Notes"], slot: 1)
        #expect(profile.workspace(for: 1)?.bundleIdentifiers == ["com.apple.Safari", "com.apple.Notes"])
        profile.name = "Study"
        profile.addApplications(bundleIdentifiers: ["com.apple.TextEdit", "com.apple.Notes"], slot: 1)
        #expect(profile.workspace(for: 1)?.name == "Study")
        #expect(profile.workspace(for: 1)?.bundleIdentifiers == ["com.apple.Safari", "com.apple.Notes", "com.apple.TextEdit"])
        let original = profile
        profile.addApplications(bundleIdentifiers: [], slot: 1)
        #expect(profile == original)
    }

    @Test func readsExistingSingleAppProfiles() throws {
        let data = Data("""
        {"id":"F6628848-21BC-47EB-801C-0D5AB125AEE2","name":"Default",
         "createdAt":0,"lastUsedAt":0,"bindings":[null,"com.apple.Safari"]}
        """.utf8)
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        #expect(profile.bundleIdentifier(for: 1) == "com.apple.Safari")
        #expect(profile.workspace(for: 1) == nil)
        #expect(Profile.normalizedBindings(profile.bindings).count == 10)
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
        let bindings = reencoded?["bindings"] as? [Any]
        #expect(bindings?[1] as? String == "com.apple.Safari")
    }

    @Test func multipleAppsCreateNamedWorkspaceWithoutStealingOtherBindings() throws {
        var profile = Profile(name: "Work")
        profile.bind(bundleIdentifier: "com.apple.Safari", slot: 1)
        profile.bind(bundleIdentifiers: ["com.apple.Safari", "com.apple.Notes", "com.apple.Safari"], slot: 2)
        #expect(profile.workspace(for: 2)?.name == "Work")
        #expect(profile.workspace(for: 2)?.bundleIdentifiers == ["com.apple.Safari", "com.apple.Notes"])
        #expect(profile.bundleIdentifier(for: 1) == "com.apple.Safari")
        profile.name = "Study time"
        profile.bind(bundleIdentifiers: ["com.apple.Notes", "com.apple.TextEdit"], slot: 2)
        #expect(profile.workspace(for: 2)?.name == "Study time")
        let restored = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        #expect(restored == profile)
        profile.name = "   "
        #expect(profile.workspace(for: 2)?.displayName == "Workspace")
    }

    @Test func singleAppRebindingAndInvalidSlotsKeepTheirExistingRules() {
        var profile = Profile(name: "Work")
        profile.bind(bundleIdentifiers: ["com.apple.Safari"], slot: 1)
        #expect(profile.bundleIdentifier(for: 1) == "com.apple.Safari")
        profile.bind(bundleIdentifier: "com.apple.Safari", slot: 3)
        #expect(profile.binding(for: 1) == nil)
        let original = profile
        profile.bind(bundleIdentifiers: ["one", "two"], slot: 10)
        profile.bind(bundleIdentifiers: [], slot: 3)
        #expect(profile == original)
        profile.bind(bundleIdentifiers: ["com.apple.Notes", "com.apple.TextEdit"], slot: 4)
        profile.removeApplication("com.apple.Notes", slot: 4)
        #expect(profile.workspace(for: 4)?.bundleIdentifiers == ["com.apple.TextEdit"])
        #expect(profile.workspace(for: 4)?.name == "Work")
    }

    @MainActor @Test func workspaceEditsDuplicateAndSurviveSavingAndReloading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("profiles.json")
        let manager = ProfileManager(storeURL: url)
        let original = try #require(manager.currentProfile)
        manager.addApplications(bundleIdentifiers: ["com.apple.Safari"], to: 4, in: original)
        manager.addApplications(bundleIdentifiers: ["com.apple.Notes"], to: 4, in: original)
        manager.profiles[0].name = "Study"
        manager.saveNow()
        let edited = try #require(manager.currentProfile)
        let copy = manager.duplicateProfile(edited)
        manager.removeWorkspaceApplication("com.apple.Safari", slot: 4, in: original)
        #expect(manager.currentProfile?.workspace(for: 4)?.name == "Study")
        #expect(manager.currentProfile?.workspace(for: 4)?.bundleIdentifiers == ["com.apple.Notes"])
        manager.addApplications(bundleIdentifiers: ["com.apple.TextEdit"], to: 4, in: original)
        #expect(manager.currentProfile?.workspace(for: 4)?.name == "Study")
        #expect(manager.currentProfile?.workspace(for: 4)?.bundleIdentifiers == ["com.apple.Notes", "com.apple.TextEdit"])
        #expect(copy.workspace(for: 4)?.bundleIdentifiers.count == 2)
        manager.saveNow()
        let reloaded = ProfileManager(storeURL: url)
        #expect(reloaded.profiles.map(\.id) == manager.profiles.map(\.id))
        #expect(reloaded.profiles.map(\.name) == manager.profiles.map(\.name))
        #expect(reloaded.profiles.map(\.bindings) == manager.profiles.map(\.bindings))
        #expect(reloaded.currentProfileID == manager.currentProfileID)
        manager.removeWorkspaceApplication("com.apple.Notes", slot: 4, in: original)
        manager.removeWorkspaceApplication("com.apple.TextEdit", slot: 4, in: original)
        #expect(manager.currentProfile?.binding(for: 4) == nil)
        manager.bind(bundleIdentifier: "com.apple.TextEdit", to: 4)
        #expect(manager.currentProfile?.bundleIdentifier(for: 4) == "com.apple.TextEdit")
        #expect(manager.currentProfile?.workspace(for: 4) == nil)
    }

    @Test func wholeWorkspaceCollectsAllBindingsAndUsesTheParentName() {
        var profile = Profile(name: "Study")
        profile.bind(bundleIdentifier: "com.apple.Safari", slot: 0)
        profile.bind(bundleIdentifiers: ["com.apple.Notes", "com.apple.Safari"], slot: 4)
        profile.bind(bundleIdentifier: "com.apple.TextEdit", slot: 9)
        #expect(profile.workspaceDefinition.name == "Study")
        #expect(profile.workspaceDefinition.bundleIdentifiers == ["com.apple.Safari", "com.apple.Notes", "com.apple.TextEdit"])
        profile.name = "Writing"
        #expect(profile.workspaceDefinition.name == "Writing")
        #expect(profile.workspace(for: 4)?.name == "Writing")
        profile.unbind(slot: 0)
        profile.unbind(slot: 9)
        #expect(profile.name == "Writing")
    }

    @MainActor @Test func legacyNamesMoveToTheLeftPanelAndNewNamesAreDistinct() throws {
        struct LegacyStore: Encodable {
            let schemaVersion = 2
            let currentProfileID: UUID
            let profiles: [Profile]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("profiles.json")
        let bindings: Bindings = [.workspace(Workspace(name: "Workspace 0", bundleIdentifiers: ["com.apple.Notes"]))]
        let legacy = Profile(name: "Default", bindings: bindings)
        let custom = Profile(name: "Personal", bindings: bindings)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(LegacyStore(currentProfileID: legacy.id, profiles: [legacy, custom])).write(to: url)
        let manager = ProfileManager(storeURL: url)
        #expect(manager.profiles.map(\.name) == ["Workspace 0", "Personal"])
        #expect(manager.currentProfile?.workspaceDefinition.bundleIdentifiers == ["com.apple.Notes"])
        let first = manager.createWorkspace()
        let second = manager.createWorkspace()
        #expect(first.name == "Workspace 1")
        #expect(second.name == "Workspace 2")
    }

}
