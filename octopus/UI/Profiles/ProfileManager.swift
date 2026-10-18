//
//  ProfileManager.swift
//  octopus
//
//  Created  on 31-01-2026.
//

import SwiftUI
import Foundation

@MainActor
final class ProfileManager: ObservableObject {
    @Published var profiles: [Profile] = [] {
        didSet { scheduleSave() }
    }
    @Published var currentProfileID: UUID? {
        didSet { scheduleSave() }
    }

    private let storeURL: URL
    private var isLoading = false
    private var saveTask: Task<Void, Never>?
    private var openingWorkspaces = Set<[String]>()

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        load()
    }

    var currentProfile: Profile? {
        guard let currentProfileID else { return nil }
        return profiles.first(where: { $0.id == currentProfileID })
    }

    func switchProfile(_ profile: Profile) {
        switchProfile(id: profile.id)
    }

    func switchProfile(id: UUID) {
        currentProfileID = id
        touchLastUsed(id: id)
    }

    func createProfile(name: String, numberOrder: String? = nil) -> Profile {
        let profile = Profile(name: name, numberOrder: numberOrder)
        profiles.append(profile)

        if currentProfileID == nil {
            currentProfileID = profile.id
        }

        return profile
    }

    func createWorkspace() -> Profile {
        let names = Set(profiles.map(\.name))
        var number = 0
        while names.contains("Workspace \(number)") { number += 1 }
        return createProfile(name: "Workspace \(number)")
    }

    func deleteProfile(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }

        if currentProfileID == profile.id {
            currentProfileID = profiles.first?.id
        }
    }

    @discardableResult
    func duplicateProfile(_ profile: Profile) -> Profile {
        let copy = Profile(
            name: "\(profile.name) Copy",
            numberOrder: profile.numberOrder,
            bindings: profile.bindings
        )
        profiles.append(copy)
        return copy
    }

    // Assigns or removes a profile number. Enforces uniqueness — returns false
    // if the requested number is already taken by another profile.
    @discardableResult
    func setProfileNumber(_ profile: Profile, number: Int?) -> Bool {
        if let number = number {
            if let existing = profileID(forNumber: number), existing != profile.id {
                return false
            }
        }

        updateProfile(id: profile.id) { updated in
            updated.profileNumber = number
        }
        return true
    }

    // Returns which of 0–9 are available for the given profile.
    // Includes numbers not taken by anyone, plus the profile's own current number.
    func availableNumbers(excluding profile: Profile) -> [Int] {
        (0...9).filter { number in
            let existing = profileID(forNumber: number)
            return existing == nil || existing == profile.id
        }
    }

    func bind(bundleIdentifier: String, to slot: Int, in profile: Profile? = nil) {
        guard let targetID = (profile ?? currentProfile)?.id else { return }
        updateProfile(id: targetID) { updated in
            updated.bind(bundleIdentifier: bundleIdentifier, slot: slot)
        }
    }

    func unbind(slot: Int, in profile: Profile? = nil) {
        guard let targetID = (profile ?? currentProfile)?.id else { return }
        updateProfile(id: targetID) { updated in
            updated.unbind(slot: slot)
        }
    }

    func addApplications(bundleIdentifiers: [String], to slot: Int, in profile: Profile) {
        updateProfile(id: profile.id) { updated in
            updated.addApplications(bundleIdentifiers: bundleIdentifiers, slot: slot)
        }
    }

    func removeWorkspaceApplication(_ identifier: String, slot: Int, in profile: Profile) {
        updateProfile(id: profile.id) { updated in
            updated.removeApplication(identifier, slot: slot)
        }
    }

    func application(for slot: Int, in profile: Profile? = nil) -> Application? {
        guard let bundleIdentifier = (profile ?? currentProfile)?.bundleIdentifier(for: slot) else {
            return nil
        }
        return Application(bundleIdentifier: bundleIdentifier)
    }

    func openWorkspace(_ workspace: Workspace) {
        let identifiers = workspace.bundleIdentifiers
        guard !identifiers.isEmpty, openingWorkspaces.insert(identifiers).inserted else { return }
        Task { @MainActor in
            defer { openingWorkspaces.remove(identifiers) }
            var opened: [Application] = []
            var failed: [String] = []
            for identifier in identifiers {
                guard let application = Application(bundleIdentifier: identifier) else {
                    failed.append(identifier)
                    continue
                }
                if !application.isRunning {
                    do {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        _ = try await application.reopen(configuration: configuration)
                    } catch {
                        failed.append(application.title)
                        continue
                    }
                }
                opened.append(application)
            }
            // Request focus for each selected app, finishing with the first app.
            for application in opened.reversed() { application.focus() }
            if !failed.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Some apps in \(workspace.displayName) could not be opened"
                alert.informativeText = failed.joined(separator: "\n")
                    + "\n\nCheck that these apps are installed, or update the workspace in Workspaces settings."
                alert.runModal()
            }
        }
    }

    func openProfileWorkspace(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        switchProfile(id: id)
        openWorkspace(profile.workspaceDefinition)
    }

    func saveNow() {
        let state = ProfileStoreState(
            schemaVersion: 3,
            currentProfileID: currentProfileID,
            profiles: profiles.map { profile in
                var normalized = profile
                normalized.bindings = Profile.normalizedBindings(profile.bindings)
                return normalized
            }
        )

        do {
            let data = try ProfileStoreState.encoder.encode(state)
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            print("Failed to save profiles: \(error)")
        }
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                let data = try Data(contentsOf: storeURL)
                let state = try ProfileStoreState.decoder.decode(ProfileStoreState.self, from: data)
                profiles = state.profiles.map { profile in
                    var normalized = profile
                    normalized.bindings = Profile.normalizedBindings(profile.bindings)
                    if state.schemaVersion < 3 { normalized.migrateWorkspaceName() }
                    return normalized
                }
                currentProfileID = state.currentProfileID
            } catch {
                print("Failed to load profiles: \(error)")
            }
        }
        if profiles.isEmpty {
            profiles = [Profile(name: "Workspace 0")]
        }
        if !profiles.contains(where: { $0.id == currentProfileID }) {
            currentProfileID = profiles.first?.id
        }
    }

    private func updateProfile(id: UUID, mutate: (inout Profile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        var updated = profiles[index]
        mutate(&updated)
        profiles[index] = updated
    }

    private func touchLastUsed(id: UUID) {
        updateProfile(id: id) { updated in
            updated.lastUsedAt = .now
        }
    }

    func profileID(forNumber number: Int) -> UUID? {
        profiles.first(where: { $0.profileNumber == number })?.id
    }

    nonisolated private static func defaultStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "octopus"
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("profiles.json")
    }
}

private struct ProfileStoreState: Codable {
    let schemaVersion: Int
    let currentProfileID: UUID?
    let profiles: [Profile]

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
