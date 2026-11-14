import AppKit

////////////////////
//// Restart Octopus after Accessibility is revoked
/// A running app cannot refresh its own trust state, and a tap the window server no longer
/// trusts can keep blocking every app's clicks and keys. Ending the process is the one step
/// that always removes its taps, so Octopus quits and comes back in its "no permission" state.
// 1. A detached helper waits for this process to end, then reopens the app.
// 2. The main thread quits normally so controllers can clean up and profiles are saved.
// 3. If the main thread does not respond quickly, it may be stuck behind a blocking tap,
//    so a background deadline ends the process at once. Once it responds, its queued tap
//    removal has already run, so normal termination gets a much longer grace period.

enum AccessibilityRevocationRecovery {
    private static let mainThreadDeadline: TimeInterval = 1
    private static let terminationGrace: TimeInterval = 10
    private static let lock = NSLock()
    private static var started = false

    static func relaunch() {
        lock.lock()
        let isFirstCall = !started
        started = true
        lock.unlock()
        guard isFirstCall else { return }

        reopenAfterExit()
        let mainThreadResponded = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            mainThreadResponded.signal()
            NSApp.terminate(nil)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard mainThreadResponded.wait(timeout: .now() + mainThreadDeadline) == .success else { _exit(0) }
            Thread.sleep(forTimeInterval: terminationGrace)
            _exit(0)
        }
    }

    // A failed helper launch must not stop the exit: freeing the user's input matters more.
    private static func reopenAfterExit() {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$2\"",
                            "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try? helper.run()
    }
}

//// Callable from any thread and only acts once per process.
//////////////////
