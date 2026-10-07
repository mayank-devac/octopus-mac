import AppKit
import Darwin

struct SidebarDesktop: Hashable {
    let id: UInt64
    let order: Int
    let number: Int?
    var displayIdentifier: String? = nil

    var title: String { number.map { "Desktop \($0)" } ?? "Full screen" }
    var windowPrefix: String { number.map { "\($0). " } ?? "Full screen · " }
}

struct SidebarEntryID: Hashable {
    let pid: pid_t
    let desktopID: UInt64?
}

// Resolve private symbols at runtime: a missing API disables Space metadata rather
// than preventing octopus from launching. Signatures follow Hammerspoon's hs.spaces.
final class SidebarSpaceReader {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias WindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private let handle: UnsafeMutableRawPointer?
    private let connection: Connection?
    private let displays: Displays?
    private let windowSpaces: WindowSpaces?

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        connection = Self.symbol("SLSMainConnectionID", handle: handle, as: Connection.self)
        displays = Self.symbol("SLSCopyManagedDisplaySpaces", handle: handle, as: Displays.self)
        windowSpaces = Self.symbol("SLSCopySpacesForWindows", handle: handle, as: WindowSpaces.self)
    }

    deinit { if let handle { dlclose(handle) } }

    private static func symbol<T>(_ name: String, handle: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    static func desktops(from displays: [[String: Any]]) -> [SidebarDesktop] {
        var result: [SidebarDesktop] = []
        var seen = Set<UInt64>()
        var number = 0
        for display in displays {
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = (space["ManagedSpaceID"] as? NSNumber ?? space["id64"] as? NSNumber)?.uint64Value,
                      let type = (space["type"] as? NSNumber)?.intValue, type == 0 || type == 4,
                      id != 0, seen.insert(id).inserted else { continue }
                if type == 0 { number += 1 }
                result.append(SidebarDesktop(id: id, order: result.count, number: type == 0 ? number : nil,
                    displayIdentifier: display["Display Identifier"] as? String))
            }
        }
        return result
    }

    func allDesktops() -> [SidebarDesktop] {
        guard let connection, let displays,
              let raw = displays(connection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Self.desktops(from: raw)
    }

    func read(windowIDs: Set<CGWindowID>, catalog: [SidebarDesktop]? = nil) -> [CGWindowID: [SidebarDesktop]] {
        guard let connection, let windowSpaces else { return [:] }
        let desktops = catalog ?? allDesktops()
        let byID = Dictionary(uniqueKeysWithValues: desktops.map { ($0.id, $0) })
        var result: [CGWindowID: [SidebarDesktop]] = [:]
        for windowID in windowIDs {
            let windows = [NSNumber(value: windowID)] as CFArray
            guard let ids = windowSpaces(connection(), 7, windows)?.takeRetainedValue() as? [NSNumber] else { continue }
            let membership = Set(ids.map(\.uint64Value))
            result[windowID] = membership.compactMap { byID[$0] }.sorted { $0.order < $1.order }
        }
        return result
    }

    // Do not infer hidden/minimised windows' desktop from their old screen bounds.
    func visibleDesktopIDs() -> Set<UInt64> {
        guard let connection, let displays,
              let raw = displays(connection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Self.visibleDesktopIDs(from: raw)
    }

    static func visibleDesktopIDs(from displays: [[String: Any]]) -> Set<UInt64> {
        Set(displays.compactMap { display in
            guard let current = display["Current Space"] as? [String: Any],
                  (current["type"] as? NSNumber)?.intValue == 0 else { return nil }
            return (current["ManagedSpaceID"] as? NSNumber ?? current["id64"] as? NSNumber)?.uint64Value
        }.filter { $0 != 0 })
    }
}
