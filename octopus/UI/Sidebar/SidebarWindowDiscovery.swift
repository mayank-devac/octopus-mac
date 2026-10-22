import AppKit
import Darwin

// kAXWindowsAttribute omits windows on other Spaces. The remote-token lookup is
// the technique used by AltTab. Never fabricate a window unless AX verifies its
// role, owner PID and Core Graphics ID. All state stays on the inventory AX queue.
final class SidebarWindowDiscovery {
    private typealias CreateElement = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private let handle: UnsafeMutableRawPointer?
    private let createElement: CreateElement?
    private struct Scan {
        var expected: Set<CGWindowID> = []
        var cursor: UInt64 = 0
        var examined = 0
        var validationCursor = 0
        var windows: [CGWindowID: AXUIElement] = [:]
    }
    private var scans: [pid_t: Scan] = [:]
    private let maximumElementID: UInt64 = 65_536

    init() {
        handle = dlopen(nil, RTLD_LAZY)
        if let handle, let address = dlsym(handle, "_AXUIElementCreateWithRemoteToken") {
            createElement = unsafeBitCast(address, to: CreateElement.self)
        } else {
            createElement = nil
        }
    }

    deinit { if let handle { dlclose(handle) } }

    func reset() { scans.removeAll() }
    func retainApplications(_ pids: Set<pid_t>) { scans = scans.filter { pids.contains($0.key) } }

    static func isEligibleRemoteWindow(role: String?, subrole: String?) -> Bool {
        // Chromium exposes tabs, restore prompts and other internal surfaces as
        // AXWindow elements. Real browser windows use AXStandardWindow; accepting
        // missing/unknown subroles here creates fake rows in the sidebar menu.
        role == (kAXWindowRole as String) && subrole == (kAXStandardWindowSubrole as String)
    }

    func read(pid: pid_t, current: [AXUIElement], candidates: Set<CGWindowID>, deadline: TimeInterval? = nil)
        -> (windows: [AXUIElement], needsAnotherPass: Bool) {
        var scan = scans[pid] ?? Scan()
        if scan.expected != candidates {
            scan.expected = candidates
            scan.examined = 0
        }
        // Closed windows can linger in CG's list. An old handle must still expose a
        // real AX window; CG presence alone is never enough to retain it.
        scan.windows = scan.windows.filter { candidates.contains($0.key) }
        let knownIDs = scan.windows.keys.sorted()
        var verifiedIDs = Set<CGWindowID>()
        var validationIncomplete = false
        let validationStart = scan.validationCursor
        for offset in 0..<knownIDs.count {
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
                validationIncomplete = true
                break
            }
            let index = (validationStart + offset) % knownIDs.count
            scan.validationCursor = (index + 1) % knownIDs.count
            let id = knownIDs[index]
            guard let element = scan.windows[id] else { continue }
            AXUIElementSetMessagingTimeout(element, 0.05)
            let role: String? = element.getAttributeValue(.role)
            let subrole: String? = element.getAttributeValue(.subrole)
            if Self.isEligibleRemoteWindow(role: role, subrole: subrole), element.getWindowID() == id {
                verifiedIDs.insert(id)
            } else {
                scan.windows.removeValue(forKey: id)
            }
        }
        for element in current {
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { break }
            if let id = element.getWindowID(), candidates.contains(id) {
                scan.windows[id] = element
                verifiedIDs.insert(id)
            }
        }
        var found = verifiedIDs
        if let createElement, !candidates.isSubset(of: found), scan.examined < Int(maximumElementID) {
            var token = Data(count: 20)
            withUnsafeBytes(of: Int32(pid)) { token.replaceSubrange(0..<4, with: $0) }
            withUnsafeBytes(of: Int32(0x636f636f)) { token.replaceSubrange(8..<12, with: $0) }
            let deadline = min(ProcessInfo.processInfo.systemUptime + 0.075, deadline ?? .infinity)
            while scan.examined < Int(maximumElementID), ProcessInfo.processInfo.systemUptime < deadline {
                withUnsafeBytes(of: scan.cursor) { token.replaceSubrange(12..<20, with: $0) }
                scan.cursor = (scan.cursor + 1) % maximumElementID
                scan.examined += 1
                if let element = createElement(token as CFData)?.takeRetainedValue() {
                    AXUIElementSetMessagingTimeout(element, 0.05)
                    var owner: pid_t = 0
                    let role: String? = element.getAttributeValue(.role)
                    let subrole: String? = element.getAttributeValue(.subrole)
                    if Self.isEligibleRemoteWindow(role: role, subrole: subrole),
                       AXUIElementGetPid(element, &owner) == .success, owner == pid,
                       let id = element.getWindowID(), candidates.contains(id) {
                        scan.windows[id] = element
                        verifiedIDs.insert(id)
                        found.insert(id)
                    }
                }
                if candidates.isSubset(of: found) || ProcessInfo.processInfo.systemUptime >= deadline { break }
            }
        }
        scans[pid] = scan
        var currentIDs = Set<CGWindowID>()
        for element in current {
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { break }
            if let id = element.getWindowID() { currentIDs.insert(id) }
        }
        let extra = scan.windows.filter { verifiedIDs.contains($0.key) && !currentIDs.contains($0.key) }
            .sorted { $0.key < $1.key }.map(\.value)
        return (current + extra, validationIncomplete || (createElement != nil && !candidates.isSubset(of: found)
            && scan.examined < Int(maximumElementID)))
    }
}
