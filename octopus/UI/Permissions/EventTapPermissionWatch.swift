import AppKit

////////////////////
//// Remove input filters when Accessibility is revoked
/// An active event tap sits in front of every app's mouse and keyboard input.
/// If Octopus loses Accessibility while one is installed, macOS keeps routing
/// input to a tap it no longer trusts, so clicks and keys never reach any app.
// Tap owners register while their tap is installed. One app-wide probe runs only while
// at least one tap is registered, so the cost does not grow with the number of taps.
// On confirmed revocation every registered tap is removed, then Octopus relaunches.

@MainActor
final class EventTapPermissionWatch {
    static let shared = EventTapPermissionWatch()

    private var removals: [ObjectIdentifier: () -> Void] = [:]
    private let probe = EventTapRevocationProbe(
        isTrusted: { EventTapTrust.isGranted() },
        onRevoked: {
            // Queue the tap removal first so it runs before the quit that relaunch requests.
            DispatchQueue.main.async { MainActor.assumeIsolated { EventTapPermissionWatch.shared.removeAllTaps() } }
            AccessibilityRevocationRecovery.relaunch()
        })

    private init() {}

    // `remove` must uninstall the owner's tap; it may call `tapRemoved(by:)` itself.
    func tapInstalled(by owner: AnyObject, remove: @escaping () -> Void) {
        removals[ObjectIdentifier(owner)] = remove
        probe.setRunning(true)
    }

    func tapRemoved(by owner: AnyObject) {
        guard removals.removeValue(forKey: ObjectIdentifier(owner)) != nil, removals.isEmpty else { return }
        probe.setRunning(false)
    }

    // Call when macOS disabled a tap. Leave it disabled (a disabled tap blocks nothing)
    // and let `reenable` run only once trust is confirmed; otherwise recovery takes over.
    func tapDisabled(reenable: @escaping @MainActor @Sendable () -> Void) {
        probe.confirmTrust(ifTrusted: reenable)
    }

    private func removeAllTaps() {
        let pending = removals
        removals = [:]
        pending.values.forEach { $0() }
    }
}

//// The probe costs nothing while no tap is installed.
//////////////////
