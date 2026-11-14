import AppKit

////////////////////
//// Remove input filters when Accessibility is revoked
/// An active event tap sits in front of every app's mouse and keyboard input.
/// If Octopus loses Accessibility while one is installed, macOS keeps routing
/// input to a tap it no longer trusts, so clicks and keys never reach any app.
// Every tap owner runs one watch and removes its tap in `onRevoked`.
// The check runs off the main thread, so a busy or stuck main thread cannot delay recovery.

@MainActor
final class EventTapPermissionWatch {
    private static let queue = DispatchQueue(label: "octopus.event-tap-permission-watch", qos: .userInitiated)
    // One check costs about a millisecond, so a short interval keeps any input freeze brief.
    private static let checkInterval: TimeInterval = 0.25
    private let isTrusted: () -> Bool
    private let recover: () -> Void
    private var onRevoked: (() -> Void)?
    private var timer: DispatchSourceTimer?

    init(isTrusted: @escaping () -> Bool = { EventTapTrust.isGranted() },
         recover: @escaping () -> Void = { AccessibilityRevocationRecovery.relaunch() }) {
        self.isTrusted = isTrusted
        self.recover = recover
    }

    func start(onRevoked: @escaping () -> Void) {
        self.onRevoked = onRevoked
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval)
        timer.setEventHandler { [weak self, isTrusted, recover] in
            guard !isTrusted() else { return }
            // Queue the tap removal first so it runs before the quit that `recover` requests.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.removeTap() } }
            recover()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        onRevoked = nil
    }

    func check() {
        guard onRevoked != nil, !isTrusted() else { return }
        removeTap()
        recover()
    }

    private func removeTap() {
        guard let onRevoked else { return }
        stop()
        onRevoked()
    }
}

//// The watch only runs while a tap is installed, so it costs nothing otherwise.
//////////////////
