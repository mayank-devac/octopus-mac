import Foundation

////////////////////
//// Decide when a failed trust probe means Accessibility is really gone
/// One failed `tapCreate` can be transient (window server busy, session switching),
/// so revocation needs several failures in a row. A successful probe resets the count.

struct EventTapRevocationDetector {
    static let requiredFailures = 2
    private(set) var failures = 0
    private(set) var isRevoked = false

    // Returns true exactly once: on the probe that confirms revocation.
    mutating func record(trusted: Bool) -> Bool {
        guard !isRevoked else { return false }
        failures = trusted ? 0 : failures + 1
        isRevoked = failures >= Self.requiredFailures
        return isRevoked
    }

    mutating func reset() {
        guard !isRevoked else { return }
        failures = 0
    }
}

//// Once revoked it stays revoked: the process is about to relaunch.
//////////////////

////////////////////
//// Probe trust in the background
/// Runs every probe on one serial queue, so a busy or stuck main thread cannot delay recovery
/// and the detector never sees concurrent updates.
// The timer runs only while `setRunning(true)`; it cancels itself the moment revocation is confirmed.
// `onRevoked` is called once, on the probe queue.

final class EventTapRevocationProbe: @unchecked Sendable {
    // A probe costs about a millisecond; with two failures needed, input frees within about a second.
    private static let checkInterval: TimeInterval = 0.5
    private static let retryDelay: TimeInterval = 0.1

    private let queue = DispatchQueue(label: "octopus.event-tap-revocation-probe", qos: .userInitiated)
    private let isTrusted: @Sendable () -> Bool
    private let onRevoked: @Sendable () -> Void
    private var detector = EventTapRevocationDetector()
    private var timer: DispatchSourceTimer?

    init(isTrusted: @escaping @Sendable () -> Bool, onRevoked: @escaping @Sendable () -> Void) {
        self.isTrusted = isTrusted
        self.onRevoked = onRevoked
    }

    func setRunning(_ running: Bool) {
        queue.async { [self] in
            if running { startTimer() } else { stopTimer(); detector.reset() }
        }
    }

    // Probes now, retrying after a short pause while the result is a single failure.
    // `ifTrusted` runs on the main thread only when trust is confirmed.
    func confirmTrust(ifTrusted: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [self] in probeUntilSettled(ifTrusted: ifTrusted) }
    }

    private func probeUntilSettled(ifTrusted: @escaping @MainActor @Sendable () -> Void) {
        guard !detector.isRevoked else { return }
        let trusted = isTrusted()
        if detector.record(trusted: trusted) { return revoke() }
        if trusted {
            DispatchQueue.main.async { MainActor.assumeIsolated { ifTrusted() } }
            return
        }
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { [self] in probeUntilSettled(ifTrusted: ifTrusted) }
    }

    private func startTimer() {
        guard timer == nil, !detector.isRevoked else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval)
        timer.setEventHandler { [weak self] in
            guard let self, !detector.isRevoked else { return }
            if detector.record(trusted: isTrusted()) { revoke() }
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func revoke() {
        stopTimer()
        onRevoked()
    }
}

//// All mutable state is confined to `queue`, which is why `@unchecked Sendable` is safe here.
//////////////////
