//
//  AccessibilityGrantReset.swift
//  octopus
//
//  Clears Octopus's own Accessibility entry when the user asks for it.
//

import Foundation

enum AccessibilityGrantReset {
    ////////////////////
    //// Clear the saved grant
    /// An entry saved for an older signature still shows as "on" in System Settings but no longer
    /// matches this build. Removing it lets the user add Octopus fresh instead of removing it by hand.
    // macOS cannot tell a stale entry from a working one, and the reset removes every entry for this
    // bundle ID (including another build's working grant). So this only ever runs on a user click.

    static func reset() async -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    //// A failed reset is harmless: the user can still remove the old entry by hand.
    //////////////////
}
