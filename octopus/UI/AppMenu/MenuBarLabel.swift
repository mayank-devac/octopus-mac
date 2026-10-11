//
//  MenuBarLabel.swift
//  octopus
//
//  The menu-bar label: the juggling glyph, optionally followed by the current
//  profile name.
//

import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var profileManager: ProfileManager
    @AppStorage("showActiveProfileInMenuBar") private var showActiveProfileInMenuBar = false

    static func labelText(for profile: Profile?) -> String {
        guard let profile else { return "" }
        return profile.name
    }

    private var text: String {
        Self.labelText(for: profileManager.currentProfile)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image("JuggleMenu")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
            if showActiveProfileInMenuBar, !text.isEmpty {
                Text(text)
            }
        }
    }
}
