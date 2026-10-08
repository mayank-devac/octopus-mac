import AppKit

// Bounds learned from real app behaviour supplement AXMinSize, which many apps do not expose.
struct WindowLayoutSizeConstraint: Equatable {
    var minimum: CGSize
    var maximum: CGSize

    static func initial(for window: WindowLayoutWindow, workArea: CGRect,
                        learned: WindowLayoutSizeConstraint? = nil) -> Self {
        let readable = WindowLayoutSettings.readabilityMinimum
        var result = Self(
            minimum: CGSize(width: max(window.minimum.width, readable.width),
                            height: max(window.minimum.height, readable.height)),
            maximum: workArea.size)
        if let learned {
            result.minimum.width = max(result.minimum.width, learned.minimum.width)
            result.minimum.height = max(result.minimum.height, learned.minimum.height)
            result.maximum.width = min(result.maximum.width, learned.maximum.width)
            result.maximum.height = min(result.maximum.height, learned.maximum.height)
        }
        return result
    }

    // A larger achieved size reveals a hidden minimum; a smaller size reveals a hidden maximum.
    func observing(requested: CGRect, achieved: CGRect, tolerance: CGFloat = 2) -> Self? {
        guard SidebarPlacementGeometry.isValid(requested), SidebarPlacementGeometry.isValid(achieved) else { return nil }
        var result = self
        if achieved.width > requested.width + tolerance { result.minimum.width = max(result.minimum.width, achieved.width) }
        if achieved.height > requested.height + tolerance { result.minimum.height = max(result.minimum.height, achieved.height) }
        if achieved.width < requested.width - tolerance { result.maximum.width = min(result.maximum.width, achieved.width) }
        if achieved.height < requested.height - tolerance { result.maximum.height = min(result.maximum.height, achieved.height) }
        guard result.minimum.width <= result.maximum.width + tolerance,
              result.minimum.height <= result.maximum.height + tolerance else { return nil }
        return result
    }
}

struct WindowLayoutAllocation {
    let frames: [WindowLayoutIdentity: CGRect]
    let peerColumns: Int
}

// This is a small constrained allocator inspired by Rectangle's observed-clamp redistribution.
// It keeps Octopus's anchor + companion-group UX instead of introducing a persistent tiling tree.
enum WindowLayoutAllocator {
    private struct PixelBounds {
        let left: Int
        let top: Int
        let right: Int
        let bottom: Int

        init(left: Int, top: Int, right: Int, bottom: Int) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }

        init(_ frame: CGRect, scale: CGFloat) {
            left = Int((frame.minX * scale).rounded())
            top = Int((frame.minY * scale).rounded())
            right = Int((frame.maxX * scale).rounded())
            bottom = Int((frame.maxY * scale).rounded())
        }

        var width: Int { right - left }
        var height: Int { bottom - top }
        func rect(scale: CGFloat) -> CGRect {
            CGRect(x: CGFloat(left) / scale, y: CGFloat(top) / scale,
                   width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        }
    }

    private struct RangeLimit {
        let minimum: Int
        let maximum: Int
    }

    static func allocate(workArea: CGRect, snap: SidebarSnapTarget, scale: CGFloat,
                         anchor: WindowLayoutIdentity, peers: [WindowLayoutIdentity],
                         constraints: [WindowLayoutIdentity: WindowLayoutSizeConstraint]) -> WindowLayoutAllocation? {
        guard snap != .maximize, !peers.isEmpty, SidebarPlacementGeometry.isValid(workArea), scale.isFinite, scale > 0,
              let anchorConstraint = constraints[anchor] else { return nil }
        let bounds = PixelBounds(workArea, scale: scale)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // Preserve the familiar single band first. Use additional columns only when constraints require it.
        let columnChoices = (snap == .left || snap == .right)
            ? Array(1...peers.count)
            : Array((1...peers.count).reversed())
        for columns in columnChoices {
            guard let allocation = allocate(bounds: bounds, snap: snap, scale: scale,
                anchor: anchor, peers: peers, columns: columns,
                anchorConstraint: anchorConstraint, constraints: constraints) else { continue }
            return WindowLayoutAllocation(frames: allocation, peerColumns: columns)
        }
        return nil
    }

    private static func allocate(bounds: PixelBounds, snap: SidebarSnapTarget, scale: CGFloat,
                                 anchor: WindowLayoutIdentity, peers: [WindowLayoutIdentity], columns: Int,
                                 anchorConstraint: WindowLayoutSizeConstraint,
                                 constraints: [WindowLayoutIdentity: WindowLayoutSizeConstraint])
        -> [WindowLayoutIdentity: CGRect]? {
        let groups = grouped(peers, columns: columns)
        guard groups.count == columns, groups.allSatisfy({ !$0.isEmpty }) else { return nil }
        let limits = groups.compactMap { group -> (width: RangeLimit, height: RangeLimit)? in
            let values = group.compactMap { constraints[$0] }
            guard values.count == group.count else { return nil }
            return (
                RangeLimit(minimum: pixels(values.map(\.minimum.width).max()!, scale: scale, up: true),
                           maximum: pixels(values.map(\.maximum.width).min()!, scale: scale, up: false)),
                RangeLimit(minimum: values.reduce(0) { $0 + pixels($1.minimum.height, scale: scale, up: true) },
                           maximum: values.reduce(0) { $0 + pixels($1.maximum.height, scale: scale, up: false) })
            )
        }
        guard limits.count == columns else { return nil }

        let horizontalRoot = snap == .left || snap == .right
        let anchorRoot = horizontalRoot
            ? range(anchorConstraint.minimum.width, anchorConstraint.maximum.width, scale: scale)
            : range(anchorConstraint.minimum.height, anchorConstraint.maximum.height, scale: scale)
        let peerRoot = horizontalRoot
            ? RangeLimit(minimum: limits.reduce(0) { $0 + $1.width.minimum },
                         maximum: limits.reduce(0) { $0 + $1.width.maximum })
            : RangeLimit(minimum: limits.map(\.height.minimum).max()!,
                         maximum: limits.map(\.height.maximum).min()!)
        let rootTotal = horizontalRoot ? bounds.width : bounds.height
        guard let rootLengths = balancedLengths(total: rootTotal, limits: [anchorRoot, peerRoot]) else { return nil }
        let anchorLength = rootLengths[0]
        let peerLength = rootLengths[1]

        let anchorBounds: PixelBounds
        let peerBounds: PixelBounds
        switch snap {
        case .left:
            anchorBounds = PixelBounds(left: bounds.left, top: bounds.top,
                right: bounds.left + anchorLength, bottom: bounds.bottom)
            peerBounds = PixelBounds(left: anchorBounds.right, top: bounds.top,
                right: bounds.right, bottom: bounds.bottom)
        case .right:
            peerBounds = PixelBounds(left: bounds.left, top: bounds.top,
                right: bounds.left + peerLength, bottom: bounds.bottom)
            anchorBounds = PixelBounds(left: peerBounds.right, top: bounds.top,
                right: bounds.right, bottom: bounds.bottom)
        case .top:
            anchorBounds = PixelBounds(left: bounds.left, top: bounds.top,
                right: bounds.right, bottom: bounds.top + anchorLength)
            peerBounds = PixelBounds(left: bounds.left, top: anchorBounds.bottom,
                right: bounds.right, bottom: bounds.bottom)
        case .bottom:
            peerBounds = PixelBounds(left: bounds.left, top: bounds.top,
                right: bounds.right, bottom: bounds.top + peerLength)
            anchorBounds = PixelBounds(left: bounds.left, top: peerBounds.bottom,
                right: bounds.right, bottom: bounds.bottom)
        case .maximize: return nil
        }

        guard contains(anchorConstraint, size: anchorBounds, scale: scale),
              let columnWidths = balancedLengths(total: peerBounds.width, limits: limits.map(\.width)) else { return nil }
        var frames = [anchor: anchorBounds.rect(scale: scale)]
        var x = peerBounds.left
        for (index, group) in groups.enumerated() {
            let columnWidth = columnWidths[index]
            let heightLimits = group.compactMap { id -> RangeLimit? in
                guard let value = constraints[id] else { return nil }
                return range(value.minimum.height, value.maximum.height, scale: scale)
            }
            guard heightLimits.count == group.count,
                  let heights = balancedLengths(total: peerBounds.height, limits: heightLimits) else { return nil }
            var y = peerBounds.top
            for (id, height) in zip(group, heights) {
                let frame = PixelBounds(left: x, top: y, right: x + columnWidth, bottom: y + height)
                guard let constraint = constraints[id], contains(constraint, size: frame, scale: scale) else { return nil }
                frames[id] = frame.rect(scale: scale)
                y += height
            }
            x += columnWidth
        }
        return frames
    }

    private static func grouped(_ peers: [WindowLayoutIdentity], columns: Int) -> [[WindowLayoutIdentity]] {
        var groups: [[WindowLayoutIdentity]] = []
        var offset = 0
        for index in 0..<columns {
            let population = peers.count / columns + (index < peers.count % columns ? 1 : 0)
            groups.append(Array(peers[offset..<(offset + population)]))
            offset += population
        }
        return groups
    }

    // Freeze minimum/maximum violations, then share all remaining pixels evenly.
    static func balancedLengths(total: Int, limits: [(minimum: Int, maximum: Int)]) -> [Int]? {
        balancedLengths(total: total, limits: limits.map { RangeLimit(minimum: $0.minimum, maximum: $0.maximum) })
    }

    private static func balancedLengths(total: Int, limits: [RangeLimit]) -> [Int]? {
        guard total > 0, !limits.isEmpty,
              limits.allSatisfy({ $0.minimum >= 0 && $0.minimum <= $0.maximum }),
              limits.reduce(0, { $0 + $1.minimum }) <= total,
              limits.reduce(0, { $0 + min(total, $1.maximum) }) >= total else { return nil }
        var low = 0
        var high = total
        while low < high {
            let middle = low + (high - low + 1) / 2
            let used = limits.reduce(0) { $0 + min($1.maximum, max($1.minimum, middle)) }
            if used <= total { low = middle } else { high = middle - 1 }
        }
        var result = limits.map { min($0.maximum, max($0.minimum, low)) }
        var remaining = total - result.reduce(0, +)
        while remaining > 0 {
            var changed = false
            for index in result.indices where result[index] < limits[index].maximum && remaining > 0 {
                result[index] += 1
                remaining -= 1
                changed = true
            }
            if !changed { return nil }
        }
        return result
    }

    private static func range(_ minimum: CGFloat, _ maximum: CGFloat, scale: CGFloat) -> RangeLimit {
        RangeLimit(minimum: pixels(minimum, scale: scale, up: true),
                   maximum: pixels(maximum, scale: scale, up: false))
    }

    private static func pixels(_ value: CGFloat, scale: CGFloat, up: Bool) -> Int {
        guard value.isFinite else { return Int.max / 4 }
        let scaled = max(0, value * scale)
        return Int(up ? ceil(scaled) : floor(scaled))
    }

    private static func contains(_ constraint: WindowLayoutSizeConstraint,
                                 size: PixelBounds, scale: CGFloat) -> Bool {
        let width = CGFloat(size.width) / scale
        let height = CGFloat(size.height) / scale
        return width + 0.5 >= constraint.minimum.width && height + 0.5 >= constraint.minimum.height
            && width <= constraint.maximum.width + 0.5 && height <= constraint.maximum.height + 0.5
    }
}
