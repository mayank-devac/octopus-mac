//
//  PreferencesProfilesView.swift
//  octopus
//
//  Created  on 28-01-2026.
//

import SwiftUI

struct PreferencesProfilesView: View {
    @EnvironmentObject var profileManager: ProfileManager
    @AppStorage("defaultNumberOrder") private var defaultNumberOrder = "rightHanded"
    @StateObject private var modifierManager: ModifierManager = {
        if let manager = AppDelegate.modifierManager {
            return manager
        }
        return ModifierManager()
    }()
    private var profiles: [Profile] { profileManager.profiles }
    
    private var sortedProfiles: [Profile] {
        let numberedProfiles = profiles.filter { $0.profileNumber != nil }
        let unnumberedProfiles = profiles.filter { $0.profileNumber == nil }
        
        let sortedNumbered = numberedProfiles.sorted { profile1, profile2 in
            guard let num1 = profile1.profileNumber, let num2 = profile2.profileNumber else {
                return false
            }
            
            if defaultNumberOrder == "rightHanded" {
                let order1 = num1 == 0 ? 0 : (11 - num1)
                let order2 = num2 == 0 ? 0 : (11 - num2)
                return order1 < order2
            } else {
                if num1 == 0 { return false }
                if num2 == 0 { return true }
                return num1 < num2
            }
        }
        
        return sortedNumbered + unnumberedProfiles.sorted { $0.createdAt < $1.createdAt }
    }
    
    @State private var selectedProfileID: UUID?
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(sortedProfiles, id: \.id, selection: $selectedProfileID) { profile in
                    HStack {
                        Text(profile.name)

                        if let number = profile.profileNumber {
                            Spacer()

                            Text("\(modifierManager.profileModifierSymbols)\(number)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                    }
                    .tag(profile.id)
                    .contextMenu {
                        Button("Duplicate Workspace") {
                            let copy = profileManager.duplicateProfile(profile)
                            selectedProfileID = copy.id
                        }
                    }
                }
                
                Divider()
                
                HStack {
                    Button(action: addProfile) {
                        Image(systemName: "plus")
                            .frame(width: 20, height:20)
                    }
                    .buttonStyle(.borderless)
                    
                    Button(action: removeProfile) {
                        Image(systemName: "minus")
                            .frame(width: 20, height:20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(sortedProfiles.count <= 1 || selectedProfileID == nil)
                    
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: 200)
            
            Divider()
            
            if let selectedProfileID = selectedProfileID,
               let selectedIndex = profiles.firstIndex(where: { $0.id == selectedProfileID }) {
                ProfileDetailView(
                    profile: $profileManager.profiles[selectedIndex],
                    profileManager: profileManager,
                    modifierManager: modifierManager
                )
            } else {
                Text("Select a workspace")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 635)
        .onAppear {
            if selectedProfileID == nil {
                selectedProfileID = profileManager.currentProfileID
            }
        }
    }
    
    private func addProfile() {
        let newProfile = profileManager.createWorkspace()
        selectedProfileID = newProfile.id
    }
    
    private func removeProfile() {
        guard sortedProfiles.count > 1,
              let selectedID = selectedProfileID,
              let selectedIndex = sortedProfiles.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        
        let selectedProfile = sortedProfiles[selectedIndex]
        
        // Pick the next profile below, or fall back to the one above
        let nextIndex = selectedIndex + 1 < sortedProfiles.count ? selectedIndex + 1 : selectedIndex - 1
        let nextProfile = sortedProfiles[nextIndex]
        
        if selectedProfile.id == profileManager.currentProfileID {
            profileManager.switchProfile(nextProfile)
        }
        
        profileManager.deleteProfile(selectedProfile)
        selectedProfileID = nextProfile.id
    }
}

struct ProfileDetailView: View {
    @Binding var profile: Profile
    @ObservedObject var profileManager: ProfileManager
    @ObservedObject var modifierManager: ModifierManager
    @AppStorage("defaultNumberOrder") private var defaultNumberOrder = "rightHanded"
    @State private var applicationSelectionError: String?
    
    
    var body: some View {
        Form {
            Section {
                TextField("Workspace name:", text: $profile.name)
                
                Picker("Number order:", selection: $profile.numberOrder) {
                    Text("Use default").tag(nil as String?)
                    Text("Right handed (0, 9, ..., 1)").tag("rightHanded" as String?)
                    Text("Left handed (1, ..., 9, 0)").tag("leftHanded" as String?)
                }
                .pickerStyle(.menu)
                
                Picker("Workspace shortcut:", selection: $profile.profileNumber) {
                    Text("Unnumbered").tag(nil as Int?)
                    
                    Divider()
                    
                    let numberOrder = profile.numberOrder ?? defaultNumberOrder
                    let sortedNumbers = profileManager.availableNumbers(excluding: profile).sorted { num1, num2 in
                        if numberOrder == "rightHanded" {
                            // Right handed: 0, 9, 8, ..., 1
                            let order1 = num1 == 0 ? 0 : (11 - num1)
                            let order2 = num2 == 0 ? 0 : (11 - num2)
                            return order1 < order2
                        } else {
                            // Left handed: 1, 2, ..., 9, 0
                            if num1 == 0 { return false }
                            if num2 == 0 { return true }
                            return num1 < num2
                        }
                    }
                    
                    ForEach(sortedNumbers, id: \.self) { number in
                        Text("\(number)").tag(number as Int?)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: profile.profileNumber) { oldValue, newValue in
                    if !profileManager.setProfileNumber(profile, number: newValue) {
                        profile.profileNumber = oldValue
                    }
                }
                .help(profile.profileNumber.map { "\(modifierManager.profileModifierSymbols)\($0)" } ?? "No shortcut assigned")
            }
            
            Section("Application Bindings") {
                Text("Add apps to each numbered binding. Its shortcut opens those apps; the workspace shortcut opens every app below. Rename the workspace above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(numbersInOrder, id: \.self) { number in
                    applicationBindingRow(number)
                }
                if let applicationSelectionError {
                    Text(applicationSelectionError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func applicationBindingRow(_ number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(number):")
                    .frame(width: 30, alignment: .leading)
                if let workspace = profile.workspace(for: number) {
                    Image(systemName: "square.stack.3d.up")
                    Text("\(workspace.bundleIdentifiers.count) apps")
                        .foregroundStyle(.secondary)
                } else if let identifier = profile.bundleIdentifier(for: number) {
                    Text(Application(bundleIdentifier: identifier)?.title ?? identifier)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not set").foregroundStyle(.tertiary)
                }
                Spacer()
                if profile.binding(for: number) != nil {
                    Button("Remove") {
                        profileManager.unbind(slot: number, in: profile)
                    }
                    .buttonStyle(.borderless)
                }
                Button(profile.binding(for: number) == nil ? "Choose apps…" : "Add apps…") {
                    chooseApplications(for: number)
                }
                .buttonStyle(.borderless)
            }
            if let workspace = profile.workspace(for: number) {
                ForEach(workspace.bundleIdentifiers, id: \.self) { identifier in
                    HStack {
                        Text(Application(bundleIdentifier: identifier)?.title ?? "\(identifier) (unavailable)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            profileManager.removeWorkspaceApplication(identifier, slot: number, in: profile)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(identifier) from \(workspace.displayName)")
                    }
                }
                .padding(.leading, 38)
            }
        }
    }
    
    private var numbersInOrder: [Int] {
        let effectiveOrder = profile.numberOrder ?? defaultNumberOrder
        
        if effectiveOrder == "leftHanded" {
            return Array(1...9) + [0]
        } else {
            return [0] + Array((1...9).reversed())
        }
    }
    
    private func chooseApplications(for number: Int) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        
        panel.prompt = "Add"
        panel.message = "Select an app to add to this shortcut. Existing apps are kept. You can also hold Command to select several apps."

        guard panel.runModal() == .OK else { return }
        let identifiers = panel.urls.compactMap { Application(url: $0)?.bundleIdentifier }
        guard identifiers.count == panel.urls.count, !identifiers.isEmpty else {
            applicationSelectionError = "One of the selected apps could not be read. The binding was not changed."
            return
        }
        applicationSelectionError = nil
        profileManager.addApplications(bundleIdentifiers: identifiers, to: number, in: profile)
    }
}
