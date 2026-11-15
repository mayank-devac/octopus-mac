import AppKit

////////////////////
//// Remember recently used apps for the centre window menu's top strip
/// Every activation and quit of a regular app moves it to the front of a short
/// saved list. The menu shows the newest ones that are not running now.
// History starts when this feature first runs; nothing is read from macOS.

@MainActor
final class RecentAppsStore {
    static let capacity = 24
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private(set) var bundleIdentifiers: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bundleIdentifiers = defaults.stringArray(forKey: PreferenceKeys.recentApps) ?? []
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let identifier = app?.activationPolicy == .regular ? app?.bundleIdentifier : nil
                Task { @MainActor in
                    guard let self, let identifier, identifier != Bundle.main.bundleIdentifier else { return }
                    self.record(identifier)
                }
            })
        }
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func record(_ bundleIdentifier: String) {
        let updated = Self.recording(bundleIdentifier, in: bundleIdentifiers, capacity: Self.capacity)
        guard updated != bundleIdentifiers else { return }
        bundleIdentifiers = updated
        defaults.set(updated, forKey: PreferenceKeys.recentApps)
    }

    /// Newest first, without apps that are running right now.
    func notRunning() -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return bundleIdentifiers.filter { !running.contains($0) }
    }

    nonisolated static func recording(_ bundleIdentifier: String, in list: [String], capacity: Int) -> [String] {
        Array(([bundleIdentifier] + list.filter { $0 != bundleIdentifier }).prefix(capacity))
    }
}

//////////////////
