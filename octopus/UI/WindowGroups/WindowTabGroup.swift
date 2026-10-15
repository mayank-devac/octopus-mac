import AppKit

struct WindowTabMember {
    var window: WindowLayoutWindow
    let originalFrame: CGRect
    var title: String
}

struct WindowTabGroup {
    let id: UUID
    var members: [WindowTabMember]
    var selected: WindowLayoutIdentity
    var frame: CGRect
    let scope: WindowLayoutScope

    var active: WindowTabMember? { members.first { $0.window.id == selected } }

    mutating func remove(_ identity: WindowLayoutIdentity) {
        guard let index = members.firstIndex(where: { $0.window.id == identity }) else { return }
        members.remove(at: index)
        if selected == identity, !members.isEmpty {
            selected = members[min(index, members.count - 1)].window.id
        }
    }
}

// Pointer geometry only. Native validation and frame writes happen after release.
enum WindowTabGeometry {
    static let stripHeight: CGFloat = 30
    static let dwell: TimeInterval = 0.6

    static func centre(of frame: CGRect) -> CGRect {
        frame.insetBy(dx: frame.width * 0.25, dy: frame.height * 0.25)
    }

    static func fits(_ frame: CGRect, windows: [WindowLayoutWindow], scope: WindowLayoutScope) -> Bool {
        SidebarPlacementGeometry.isValid(frame) && !windows.isEmpty
            && Set(windows.map(\.id.window)).count == windows.count
            && windows.allSatisfy {
                $0.eligible && $0.scope == scope
                    && frame.width >= max(WindowLayoutSettings.readabilityMinimum.width, $0.minimum.width)
                    && frame.height >= max(WindowLayoutSettings.readabilityMinimum.height, $0.minimum.height)
            }
    }

    static func groupFrame(target: CGRect, workArea: CGRect) -> CGRect {
        // Make space for the strip when the target touches the menu bar.
        let top = max(target.minY, workArea.minY + stripHeight)
        return CGRect(x: target.minX, y: top, width: target.width, height: target.maxY - top)
    }

    static func detachedFrame(original: CGRect, at point: CGPoint?, workArea: CGRect) -> CGRect {
        let size = CGSize(width: min(original.width, workArea.width), height: min(original.height, workArea.height))
        let origin = point.map { CGPoint(x: $0.x - size.width / 2, y: $0.y) } ?? original.origin
        return CGRect(x: min(max(origin.x, workArea.minX), workArea.maxX - size.width),
                      y: min(max(origin.y, workArea.minY), workArea.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

struct WindowTabHover {
    let source: SidebarWindowID
    private(set) var target: SidebarWindowID?
    private(set) var beganAt: TimeInterval = 0

    mutating func update(target next: SidebarWindowID?, at time: TimeInterval) {
        let next = next == source ? nil : next
        if target != next { target = next; beganAt = time }
    }

    func isReady(at time: TimeInterval) -> Bool {
        target != nil && time - beganAt >= WindowTabGeometry.dwell
    }
}

struct WindowTabPlacementActivity {
    static let began = Notification.Name("octopus.tabPlacementBegan")
    static let ended = Notification.Name("octopus.tabPlacementEnded")
    let id = UUID()
}
