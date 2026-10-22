import AppKit

struct MissionControlLayout: Equatable {
    struct Icon: Equatable {
        let windowID: SidebarWindowID
        let frame: CGRect
    }

    struct Tile: Equatable {
        let desktop: SidebarDesktop
        let frame: CGRect
        let icons: [Icon]
        let isActive: Bool
    }

    let size: CGSize
    let tiles: [Tile]
    let scale: CGFloat
    static let tileWidth: CGFloat = 112
    static let padding: CGFloat = 12
    static let gap: CGFloat = 8

    static func make(snapshot: MissionControlSnapshot, screenID: String, screenSize: CGSize,
                     availableSize: CGSize? = nil) -> Self? {
        guard screenSize.width.isFinite, screenSize.height.isFinite,
              screenSize.width > 0, screenSize.height > 0,
              let screen = snapshot.screens.first(where: { $0.id == screenID }),
              MissionControlSnapshot.validBounds(screen.bounds) else { return nil }
        let desktops = snapshot.desktops(on: screenID)
        guard !desktops.isEmpty else { return nil }
        let available = availableSize ?? screenSize
        guard available.width.isFinite, available.height.isFinite,
              available.width > 0, available.height > 0 else { return nil }
        let maximumWidth = min(screenSize.width * 0.6, available.width)
        let maximumHeight = min(screenSize.height * 0.7, available.height)
        let tileHeight = tileWidth * screenSize.height / screenSize.width
        let rows = min(desktops.count, max(1, Int((maximumHeight - padding * 2 + gap) / (tileHeight + gap))))
        let columns = (desktops.count + rows - 1) / rows
        let naturalWidth = CGFloat(columns) * tileWidth + CGFloat(columns - 1) * gap + padding * 2
        let naturalHeight = CGFloat(rows) * tileHeight + CGFloat(rows - 1) * gap + padding * 2
        let scale = min(1, maximumWidth / naturalWidth, maximumHeight / naturalHeight)
        let windows = snapshot.windows.filter { $0.screenID == screenID }
        let tiles = desktops.enumerated().map { index, desktop in
            let frame = CGRect(x: (padding + CGFloat(index / rows) * (tileWidth + gap)) * scale,
                               y: (padding + CGFloat(index % rows) * (tileHeight + gap)) * scale,
                               width: tileWidth * scale, height: tileHeight * scale)
            let members = windows.filter { $0.desktopIDs.contains(desktop.id) }
            let icons = place(windows: members, screen: screen.bounds, tile: CGSize(width: tileWidth, height: tileHeight))
                .map { Icon(windowID: $0.windowID,
                            frame: CGRect(x: $0.frame.minX * scale, y: $0.frame.minY * scale,
                                          width: $0.frame.width * scale, height: $0.frame.height * scale)) }
            return Tile(desktop: desktop, frame: frame, icons: icons, isActive: snapshot.activeIDs.contains(desktop.id))
        }
        return Self(size: CGSize(width: naturalWidth * scale, height: naturalHeight * scale), tiles: tiles, scale: scale)
    }

    static func centre(window: CGRect, screen: CGRect, tile: CGSize, iconSize: CGFloat) -> CGPoint {
        let inset = iconSize / 2 + 3
        return CGPoint(x: min(tile.width - inset, max(inset, (window.midX - screen.minX) / screen.width * tile.width)),
                       y: min(tile.height - inset, max(inset, (window.midY - screen.minY) / screen.height * tile.height)))
    }

    static func place(windows: [MissionControlSnapshot.Window], screen: CGRect, tile: CGSize) -> [Icon] {
        let sorted = windows.sorted { ($0.id.pid, $0.id.windowID) < ($1.id.pid, $1.id.windowID) }
        for size in [CGFloat(20), CGFloat(14)] {
            for snapToGrid in [false, true] {
                if let icons = arrange(sorted, screen: screen, tile: tile, size: size,
                                       snapToGrid: snapToGrid, allowOverlap: false) { return icons }
            }
        }
        return arrange(sorted, screen: screen, tile: tile, size: 14, snapToGrid: false, allowOverlap: true) ?? []
    }

    private static func arrange(_ windows: [MissionControlSnapshot.Window], screen: CGRect, tile: CGSize,
                                size: CGFloat, snapToGrid: Bool, allowOverlap: Bool) -> [Icon]? {
        let size = min(size, max(1, min(tile.width, tile.height) - 6))
        let inset = size / 2 + 3
        let columns = max(1, Int((tile.width - 6) / (size + 2)))
        let rows = max(1, Int((tile.height - 6) / (size + 2)))
        let horizontalSpan = tile.width - inset * 2
        let verticalSpan = tile.height - inset * 2
        var cells: [CGPoint] = []
        cells.reserveCapacity(rows * columns)
        for row in 0..<rows {
            let y: CGFloat
            if rows == 1 { y = tile.height / 2 }
            else { y = inset + CGFloat(row) * verticalSpan / CGFloat(rows - 1) }
            for column in 0..<columns {
                let x: CGFloat
                if columns == 1 { x = tile.width / 2 }
                else { x = inset + CGFloat(column) * horizontalSpan / CGFloat(columns - 1) }
                cells.append(CGPoint(x: x, y: y))
            }
        }
        var result: [Icon] = []
        for window in windows {
            let preferred = centre(window: window.bounds, screen: screen, tile: tile, iconSize: size)
            let orderedCells = cells.sorted { lhs, rhs in
                let left = distance(lhs, preferred), right = distance(rhs, preferred)
                if left != right { return left < right }
                return (lhs.y, lhs.x) < (rhs.y, rhs.x)
            }
            let candidates = snapToGrid ? orderedCells : [preferred] + orderedCells
            let frames = candidates.map { CGRect(x: $0.x - size / 2, y: $0.y - size / 2, width: size, height: size) }
            let free = frames.first { candidate in
                !result.contains { $0.frame.insetBy(dx: -1, dy: -1).intersects(candidate) }
            }
            let selected: CGRect
            if let free { selected = free }
            else {
                guard allowOverlap else { return nil }
                // Equal overlap keeps the candidate nearest the window's real position.
                selected = frames.enumerated().min { lhs, rhs in
                    let left = overlap(lhs.element, icons: result), right = overlap(rhs.element, icons: result)
                    return left == right ? lhs.offset < rhs.offset : left < right
                }!.element
            }
            result.append(Icon(windowID: window.id, frame: selected))
        }
        return result
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        pow(lhs.x - rhs.x, 2) + pow(lhs.y - rhs.y, 2)
    }

    private static func overlap(_ frame: CGRect, icons: [Icon]) -> CGFloat {
        icons.reduce(0) { total, icon in
            let intersection = frame.intersection(icon.frame)
            return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
        }
    }
}
