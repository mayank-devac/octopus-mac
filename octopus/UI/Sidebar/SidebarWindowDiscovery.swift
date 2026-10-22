import AppKit
import Darwin

// kAXWindowsAttribute omits windows on other Spaces. The remote-token lookup is
// the technique used by AltTab. Never fabricate a window unless AX verifies its
// role, owner PID and Core Graphics ID. All state stays on the inventory AX queue.
final class SidebarWindowDiscovery {
    private enum HandleLiveness {
        case valid(CGWindowID)
        case invalid
        case unknown
    }

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

    private static func liveness(of element: AXUIElement) -> HandleLiveness {
        var role: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if roleError == .invalidUIElement { return .invalid }
        guard roleError == .success else { return .unknown }
        var id = CGWindowID(0)
        switch _AXUIElementGetWindow(element, &id) {
        case .success where id != kCGNullWindowID: return .valid(id)
        case .invalidUIElement: return .invalid
        default: return .unknown
        }
    }

    func read(pid: pid_t, current: [AXUIElement], candidates: Set<CGWindowID>, deadline: TimeInterval? = nil,
              seeds: [CGWindowID: AXUIElement] = [:])
        -> (windows: [AXUIElement], needsAnotherPass: Bool, invalidatedIDs: Set<CGWindowID>) {
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
        var invalidatedIDs = Set<CGWindowID>()
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
            switch Self.liveness(of: element) {
            case .invalid:
                scan.windows.removeValue(forKey: id)
                invalidatedIDs.insert(id)
                continue
            case .unknown:
                continue
            case .valid(let actualID) where actualID != id:
                scan.windows.removeValue(forKey: id)
                invalidatedIDs.insert(id)
                continue
            case .valid:
                break
            }
            let role: String? = element.getAttributeValue(.role)
            let subrole: String? = element.getAttributeValue(.subrole)
            if Self.isEligibleRemoteWindow(role: role, subrole: subrole) {
                verifiedIDs.insert(id)
            } else if role != nil, subrole != nil {
                scan.windows.removeValue(forKey: id)
            }
        }
        var currentIDs = Set<CGWindowID>()
        var acceptedCurrent: [AXUIElement] = []
        for element in current {
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { break }
            switch Self.liveness(of: element) {
            case .valid(let id):
                acceptedCurrent.append(element)
                guard candidates.contains(id) else { continue }
                currentIDs.insert(id)
                scan.windows[id] = element
                verifiedIDs.insert(id)
            case .unknown:
                acceptedCurrent.append(element)
            case .invalid:
                continue
            }
        }
        for (expectedID, element) in seeds {
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { break }
            switch Self.liveness(of: element) {
            case .valid(let id) where id == expectedID && candidates.contains(id):
                scan.windows[id] = element
                verifiedIDs.insert(id)
            case .invalid:
                invalidatedIDs.insert(expectedID)
                scan.windows.removeValue(forKey: expectedID)
            case .valid:
                invalidatedIDs.insert(expectedID)
                scan.windows.removeValue(forKey: expectedID)
            case .unknown:
                continue
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
                       case .valid(let id) = Self.liveness(of: element), candidates.contains(id) {
                        scan.windows[id] = element
                        verifiedIDs.insert(id)
                        found.insert(id)
                    }
                }
                if candidates.isSubset(of: found) || ProcessInfo.processInfo.systemUptime >= deadline { break }
            }
        }
        scans[pid] = scan
        let extra = scan.windows.filter { verifiedIDs.contains($0.key) && !currentIDs.contains($0.key) }
            .sorted { $0.key < $1.key }.map(\.value)
        return (acceptedCurrent + extra, validationIncomplete || (createElement != nil && !candidates.isSubset(of: found)
            && scan.examined < Int(maximumElementID)), invalidatedIDs)
    }
}
