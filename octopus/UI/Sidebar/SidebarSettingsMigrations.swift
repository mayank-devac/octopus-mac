import AppKit

////////////////////
//// Sidebar settings migrations
/// Each migration carries a value saved by an older build into the key or shape read today.
// They run from `registerDefaults()` before defaults are registered, and remove the old value once moved.

extension SidebarSettings {
    // The former on/off "sidebarAutoHide" maps to Hide / Stay visible; an unset value gets the new default.
    static func migrateLegacyAutoHide(in defaults: UserDefaults = .standard) {
        guard let legacy = defaults.object(forKey: "sidebarAutoHide") as? Bool else { return }
        if defaults.object(forKey: idleBehaviorKey) == nil {
            defaults.set((legacy ? SidebarIdleBehavior.hide : .stayVisible).rawValue, forKey: idleBehaviorKey)
        }
        defaults.removeObject(forKey: "sidebarAutoHide")
    }

    ////////////////////
    //// Migrate per-display snap distance
    /// Builds up to 2.1.7 saved snap distance inside each display's preference when separate display
    /// settings were on. It is now one app-wide value, so those users fell back to the default.
    // The primary display's value wins, and a global value the user already changed is kept. Stripping
    // the old field from each display's preference afterwards makes this run only once.

    private struct LegacyDisplaySnapDistance: Decodable {
        struct Configuration: Decodable { var snapDistance: Double? }
        var configuration: Configuration
    }

    static func migrateLegacyDisplaySnapDistance(primaryDisplayID: String? = monitorID(CGMainDisplayID()),
                                                in defaults: UserDefaults = .standard) {
        guard var saved = defaults.dictionary(forKey: displayPreferencesKey) else { return }
        let legacy = saved.compactMapValues { value -> Double? in
            guard let data = value as? Data else { return nil }
            return (try? JSONDecoder().decode(LegacyDisplaySnapDistance.self, from: data))?.configuration.snapDistance
        }
        guard !legacy.isEmpty else { return }

        let global = defaults.object(forKey: snapDistanceKey) as? Double
        let legacyValue = primaryDisplayID.flatMap { legacy[$0] }
            ?? legacy.sorted { $0.key < $1.key }.first { $0.value != SidebarSettingsValues.defaultSnapDistance }?.value
        if defaults.bool(forKey: multiDisplayKey), global == nil || global == SidebarSettingsValues.defaultSnapDistance,
           let legacyValue {
            defaults.set(normalizedSnapDistance(legacyValue), forKey: snapDistanceKey)
        }

        for id in legacy.keys {
            guard let data = saved[id] as? Data,
                  let preference = try? JSONDecoder().decode(SidebarDisplayPreference.self, from: data),
                  let stripped = try? JSONEncoder().encode(preference) else { continue }
            saved[id] = stripped
        }
        defaults.set(saved, forKey: displayPreferencesKey)
    }

    //// Each display's other saved settings stay as they were.
    //////////////////
}

//// A renamed key or stored raw value needs a migration here, or users fall back to the default.
//////////////////
