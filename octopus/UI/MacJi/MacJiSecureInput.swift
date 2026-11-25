//
//  MacJiSecureInput.swift
//  octopus
//
//  Detects macOS Secure Event Input. While any app holds it (Terminal's
//  Secure Keyboard Entry, password fields, password managers) no event tap
//  receives keys, so MacJi cannot see the trigger.
//

import AppKit
import IOKit

struct MacJiSecureInputHolder: Equatable {
    let pid: pid_t
    let name: String
}

enum MacJiSecureInput {
    static let pidKey = "kCGSSessionSecureInputPID"
    static let onConsoleKey = "kCGSSessionOnConsoleKey"

    ////////////////////
    //// Who holds Secure Input
    /// The IORegistry console-user entry is the live source; CGSessionCopyCurrentDictionary
    /// caches a stale PID per process and named the wrong app.

    static func holder() -> MacJiSecureInputHolder? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0,
              let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]],
              let pid = holderPID(inConsoleUsers: users) else { return nil }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Another app"
        return MacJiSecureInputHolder(pid: pid, name: name)
    }

    /// Only the session on the console matters; others belong to fast-user-switched users.
    static func holderPID(inConsoleUsers users: [[String: Any]]) -> pid_t? {
        guard let session = users.first(where: { ($0[onConsoleKey] as? Bool) == true }),
              let pid = (session[pidKey] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    //// A missing key or PID 0 means Secure Input is off.
    //////////////////

    /// How to release Secure Input, worded for the app that holds it.
    static func turnOffSteps(for holder: MacJiSecureInputHolder) -> String {
        if holder.name == "Terminal" {
            return "To fix it, open Terminal and click Terminal(top-left corner) › Secure Keyboard Entry in the menu bar so it's unchecked. Still stuck? Quit Terminal (⌘Q)."
        }
        return "To fix it, close any password field in \(holder.name). Still stuck? Quit \(holder.name) (⌘Q)."
    }
}
