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
    enum WindowMembershipState {
        case verified([SidebarDesktop])
        case failed
        case notRead
    }

    struct Catalog {
        let desktops: [SidebarDesktop]
        let activeIDs: Set<UInt64>

        func desktops(on screenID: String) -> [SidebarDesktop] {
            desktops.filter { $0.displayIdentifier == screenID || $0.displayIdentifier == "Main" }
                .sorted { $0.order < $1.order }
        }

        // Match the live order, never the index cached when the map was drawn.
        func selectionIndex(screenID: String, desktopID: UInt64, controlCount: Int) -> Int? {
            let ordered = desktops(on: screenID)
            guard ordered.count == controlCount, Set(ordered.map(\.id)).count == ordered.count,
                  Set(ordered.compactMap(\.displayIdentifier)).count == 1 else { return nil }
            return ordered.firstIndex { $0.id == desktopID }
        }
    }
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
        readCatalog()?.desktops ?? []
    }

    func readCatalog() -> Catalog? {
        guard let connection, let displays,
              let raw = displays(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return Self.catalog(from: raw)
    }

    static func catalog(from displays: [[String: Any]]) -> Catalog {
        let desktops = Self.desktops(from: displays)
        let knownIDs = Set(desktops.map(\.id))
        let activeIDs = Set(displays.compactMap { display -> UInt64? in
            guard let current = display["Current Space"] as? [String: Any],
                  let id = (current["ManagedSpaceID"] as? NSNumber ?? current["id64"] as? NSNumber)?.uint64Value,
                  knownIDs.contains(id) else { return nil }
            return id
        })
        return Catalog(desktops: desktops, activeIDs: activeIDs)
    }

    func read(windowIDs: Set<CGWindowID>, catalog: [SidebarDesktop]? = nil) -> [CGWindowID: [SidebarDesktop]] {
        let desktops: [SidebarDesktop]
        if let catalog {
            desktops = catalog
        } else {
            guard let discovered = readCatalog()?.desktops else { return [:] }
            desktops = discovered
        }
        var result: [CGWindowID: [SidebarDesktop]] = [:]
        for windowID in windowIDs {
            if case .verified(let membership) = readResult(windowID: windowID, desktops: desktops,
                                                          deadline: nil) {
                result[windowID] = membership
            }
        }
        return result
    }

    // Space membership is a per-window private API call. Keep this operation
    // bounded when it is part of a larger snapshot read. A missing result is
    // failure, not an empty membership, so callers can retain verified state.
    func readResult(windowID: CGWindowID, catalog: [SidebarDesktop]? = nil,
                   deadline: TimeInterval? = nil) -> WindowMembershipState {
        let desktops: [SidebarDesktop]
        if let catalog {
            desktops = catalog
        } else {
            guard let discovered = readCatalog()?.desktops else {
                return .failed
            }
            desktops = discovered
        }
        return readResult(windowID: windowID, desktops: desktops, deadline: deadline)
    }

    private func readResult(windowID: CGWindowID, desktops: [SidebarDesktop],
                            deadline: TimeInterval?) -> WindowMembershipState {
        guard let connection, let windowSpaces else {
            return .failed
        }
        let byID = Dictionary(uniqueKeysWithValues: desktops.map { ($0.id, $0) })
        guard deadline.map({ ProcessInfo.processInfo.systemUptime < $0 }) ?? true else {
            return .notRead
        }
        let windows = [NSNumber(value: windowID)] as CFArray
        guard let ids = windowSpaces(connection(), 7, windows)?.takeRetainedValue() as? [NSNumber] else {
            return .failed
        }
        let membership = Set(ids.map(\.uint64Value))
        return .verified(
            membership.compactMap { byID[$0] }.sorted { $0.order < $1.order })
    }

    // A window assigned to every desktop of a display (Finder, or any app set to
    // "Assign To: All Desktops") reports one membership per desktop. Listing it in
    // each group duplicates the same window, so keep it only on the desktop the
    // display is showing; it follows the user when the desktop changes.
    static func collapsingAllDesktopsMembership(_ membership: [SidebarDesktop], catalog: [SidebarDesktop],
                                                visible: Set<UInt64>) -> [SidebarDesktop] {
        guard membership.count > 1 else { return membership }
        var result: [SidebarDesktop] = []
        for (display, members) in Dictionary(grouping: membership, by: \.displayIdentifier) {
            let all = catalog.filter { $0.number != nil && $0.displayIdentifier == display }
            let memberIDs = Set(members.map(\.id))
            guard display != nil, members.count > 1, all.allSatisfy({ memberIDs.contains($0.id) }) else {
                result += members
                continue
            }
            result.append(members.first { visible.contains($0.id) } ?? members[0])
        }
        return result.sorted { $0.order < $1.order }
    }

    // Do not infer hidden/minimised windows' desktop from their old screen bounds.
    func visibleDesktopIDs() -> Set<UInt64> {
        guard let connection, let displays,
              let raw = displays(connection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Self.visibleDesktopIDs(from: raw)
    }

    func visibleDesktop(on displayID: String) -> SidebarDesktop? {
        guard let connection, let displays,
              let raw = displays(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return Self.visibleDesktop(on: displayID, from: raw)
    }

    static func visibleDesktop(on displayID: String, from displays: [[String: Any]]) -> SidebarDesktop? {
        // With separate Spaces disabled, macOS reports one shared "Main" display.
        guard let display = displays.first(where: { $0["Display Identifier"] as? String == displayID })
                ?? displays.first(where: { $0["Display Identifier"] as? String == "Main" }),
              let current = display["Current Space"] as? [String: Any],
              (current["type"] as? NSNumber)?.intValue == 0,
              let id = (current["ManagedSpaceID"] as? NSNumber ?? current["id64"] as? NSNumber)?.uint64Value,
              let desktop = desktops(from: displays).first(where: { $0.id == id && $0.number != nil }) else { return nil }
        return desktop
    }

    static func visibleDesktopIDs(from displays: [[String: Any]]) -> Set<UInt64> {
        Set(displays.compactMap { display in
            guard let current = display["Current Space"] as? [String: Any],
                  (current["type"] as? NSNumber)?.intValue == 0 else { return nil }
            return (current["ManagedSpaceID"] as? NSNumber ?? current["id64"] as? NSNumber)?.uint64Value
        }.filter { $0 != 0 })
    }
}
