//
//  PreferencesView.swift
//  octopus
//
//  Created  on 26-01-2026.
//

import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            PreferencesGeneralView()
                .tabItem { Label("General", systemImage: "gear")}

            PreferencesSidebarView()
                .tabItem { Label("Sidebar", systemImage: "sidebar.right") }
            
            PreferencesProfilesView()
                .tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }
            
            PreferencesShortcutsView()
                .tabItem { Label("Shortcuts", systemImage: "command") }
        }
        .frame(width: 650)
    }
}

#Preview {
    PreferencesView()
        .environmentObject(ProfileManager())
}
