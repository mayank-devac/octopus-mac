import AppKit

// Bounds learned from real app behaviour supplement AXMinSize, which many apps do not expose.
struct WindowLayoutSizeConstraint: Equatable {
    var minimum: CGSize
    var maximum: CGSize

    // Read-only previews use app-reported bounds, never bounds inferred from a single old resize.
    static func reported(for window: WindowLayoutWindow, workArea: CGRect) -> Self {
        initial(for: window, workArea: workArea)
    }

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

    // Successful setters plus matching fresh readback let the caller use these observed bounds for reflow.
    // They are temporary constraints, not proof of an app's permanent minimum/maximum size.
    func observing(requested: CGRect, achieved: CGRect, tolerance: CGFloat = 2) -> Self? {
        guard SidebarPlacementGeometry.isValid(requested), SidebarPlacementGeometry.isValid(achieved),
              tolerance.isFinite, tolerance >= 0 else { return nil }
        var result = self
        if achieved.width > requested.width + tolerance { result.minimum.width = max(result.minimum.width, achieved.width) }
        if achieved.height > requested.height + tolerance { result.minimum.height = max(result.minimum.height, achieved.height) }
        if achieved.width < requested.width - tolerance { result.maximum.width = min(result.maximum.width, achieved.width) }
        if achieved.height < requested.height - tolerance { result.maximum.height = min(result.maximum.height, achieved.height) }
        guard result.minimum.width <= result.maximum.width,
              result.minimum.height <= result.maximum.height else { return nil }
        return result
    }
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

    // Prefer familiar bands, then bounded shelf shapes. Reject invalid input before pixel conversion.
    static func allocate(workArea: CGRect, snap: SidebarSnapTarget, scale: CGFloat,
                         anchor: WindowLayoutIdentity, peers: [WindowLayoutIdentity],
                         constraints: [WindowLayoutIdentity: WindowLayoutSizeConstraint],
                         frozenGroups: [[WindowLayoutIdentity]]? = nil,
                         requestedAnchorLength: CGFloat? = nil,
                         onEdgeGroups: ([[WindowLayoutIdentity]]) -> Void = { _ in }) -> [WindowLayoutIdentity: CGRect]? {
        let identities = [anchor] + peers
        guard snap != .maximize, !peers.isEmpty, peers.count <= 32,
              Set(identities).count == identities.count,
              SidebarPlacementGeometry.isValid(workArea), scale.isFinite, scale > 0,
              let anchorConstraint = constraints[anchor] else { return nil }
        // Leave headroom for coordinates, differences and sums across up to 32 companion windows.
        let limit = CGFloat(Int.max / 64)
        guard [workArea.minX, workArea.minY, workArea.maxX, workArea.maxY].allSatisfy({
            ($0 * scale).isFinite && abs($0 * scale) < limit
        }), identities.allSatisfy({ id in
            guard let value = constraints[id] else { return false }
            let sizes = [value.minimum.width, value.minimum.height, value.maximum.width, value.maximum.height]
            return sizes.allSatisfy { $0.isFinite && $0 >= 0 && ($0 * scale).isFinite && $0 * scale < limit }
                && value.minimum.width <= value.maximum.width && value.minimum.height <= value.maximum.height
        }) else { return nil }
        let bounds = PixelBounds(workArea, scale: scale)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        if let groups = frozenGroups {
            let members = groups.flatMap { $0 }
            guard !snap.isCorner, !groups.isEmpty, groups.allSatisfy({ !$0.isEmpty }),
                  members.count == peers.count, Set(members) == Set(peers) else { return nil }
            return allocate(bounds: bounds, snap: snap, scale: scale, anchor: anchor, groups: groups,
                anchorConstraint: anchorConstraint, constraints: constraints, requestedAnchorLength: requestedAnchorLength)
        }
        guard requestedAnchorLength == nil else { return nil }
        if snap.isCorner {
            return allocateCorner(bounds: bounds, snap: snap, scale: scale, anchor: anchor,
                peers: peers, anchorConstraint: anchorConstraint, constraints: constraints)
        }

        // Preserve the familiar single band first. Use additional columns only when constraints require it.
        let columnChoices = (snap == .left || snap == .right)
            ? Array(1...peers.count)
            : Array((1...peers.count).reversed())
        for columns in columnChoices {
            let groups = grouped(peers, columns: columns)
            guard let allocation = allocate(bounds: bounds, snap: snap, scale: scale,
                anchor: anchor, groups: groups,
                anchorConstraint: anchorConstraint, constraints: constraints) else { continue }
            onEdgeGroups(groups)
            return allocation
        }
        // A tall window may need its own column, while several short windows share the next one.
        let horizontal = snap == .left || snap == .right
        let availableHeight = CGFloat(bounds.height) / scale
        let capacities = horizontal ? [availableHeight]
            : [availableHeight / 2, availableHeight - anchorConstraint.minimum.height]
        for height in capacities where height > 0 {
            guard let groups = shelfGroups(peers, constraints: constraints, height: height),
                  let allocation = allocate(bounds: bounds, snap: snap, scale: scale,
                    anchor: anchor, groups: groups, anchorConstraint: anchorConstraint,
                    constraints: constraints) else { continue }
            onEdgeGroups(groups)
            return allocation
        }
        return nil
    }

    private static func allocate(bounds: PixelBounds, snap: SidebarSnapTarget, scale: CGFloat,
                                 anchor: WindowLayoutIdentity, groups: [[WindowLayoutIdentity]],
                                 anchorConstraint: WindowLayoutSizeConstraint,
                                 constraints: [WindowLayoutIdentity: WindowLayoutSizeConstraint],
                                 requestedAnchorLength: CGFloat? = nil)
        -> [WindowLayoutIdentity: CGRect]? {
        let columns = groups.count
        guard columns > 0, groups.allSatisfy({ !$0.isEmpty }) else { return nil }
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
        let rootLengths: [Int]
        if let requested = requestedAnchorLength {
            guard requested.isFinite, (requested * scale).isFinite else { return nil }
            let lower = max(anchorRoot.minimum, rootTotal - peerRoot.maximum)
            let upper = min(anchorRoot.maximum, rootTotal - peerRoot.minimum)
            guard lower > 0, lower <= upper, upper < rootTotal else { return nil }
            let length = Int(min(max(requested * scale, CGFloat(lower)), CGFloat(upper)).rounded())
            rootLengths = [length, rootTotal - length]
        } else {
            guard let lengths = balancedLengths(total: rootTotal, limits: [anchorRoot, peerRoot]) else { return nil }
            rootLengths = lengths
        }
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
        case .maximize, .topLeft, .topRight, .bottomLeft, .bottomRight: return nil
        }

        guard contains(anchorConstraint, size: anchorBounds, scale: scale),
              var frames = allocateRegion(peerBounds, groups: groups, constraints: constraints, scale: scale) else { return nil }
        frames[anchor] = anchorBounds.rect(scale: scale)
        return frames
    }

    // Two regions remain beside a corner: a full-height band and the opposite quarter.
    // Try MRU-preserving populations near 2:1, then the same bounded column shapes as edge layouts.
    private static func allocateCorner(bounds: PixelBounds, snap: SidebarSnapTarget, scale: CGFloat,
                                       anchor: WindowLayoutIdentity, peers: [WindowLayoutIdentity],
                                       anchorConstraint: WindowLayoutSizeConstraint,
                                       constraints: [WindowLayoutIdentity: WindowLayoutSizeConstraint]) -> [WindowLayoutIdentity: CGRect]? {
        guard peers.count >= 2 else { return nil }
        let preferred = min(peers.count - 1, max(1, Int((Double(peers.count) * 2 / 3).rounded())))
        let populations = (1..<peers.count).sorted {
            let a = abs($0 - preferred), b = abs($1 - preferred)
            return a == b ? $0 < $1 : a < b
        }
        for population in populations {
            let bandPeers = Array(peers.prefix(population))
            let quarterPeers = Array(peers.dropFirst(population))
            let bandShapes = regionShapes(bandPeers, constraints: constraints, heights: [CGFloat(bounds.height) / scale])
            let quarterShapes = regionShapes(quarterPeers, constraints: constraints,
                heights: [CGFloat(bounds.height) / scale / 2, CGFloat(bounds.height) / scale - anchorConstraint.minimum.height])
            for bandGroups in bandShapes {
                guard let band = regionLimit(bandGroups, constraints: constraints, scale: scale),
                      bounds.height >= band.height.minimum, bounds.height <= band.height.maximum else { continue }
                for quarterGroups in quarterShapes {
                    guard let quarter = regionLimit(quarterGroups, constraints: constraints, scale: scale) else { continue }
                    let anchorWidth = range(anchorConstraint.minimum.width, anchorConstraint.maximum.width, scale: scale)
                    let sharedWidth = RangeLimit(minimum: max(anchorWidth.minimum, quarter.width.minimum),
                                                 maximum: min(anchorWidth.maximum, quarter.width.maximum))
                    guard let widths = balancedLengths(total: bounds.width, limits: [sharedWidth, band.width]),
                          let heights = balancedLengths(total: bounds.height,
                            limits: [range(anchorConstraint.minimum.height, anchorConstraint.maximum.height, scale: scale), quarter.height]) else { continue }
                    let splitX = snap.isRightCorner ? bounds.right - widths[0] : bounds.left + widths[0]
                    let splitY = snap.isBottomCorner ? bounds.bottom - heights[0] : bounds.top + heights[0]
                    let columnLeft = snap.isRightCorner ? splitX : bounds.left
                    let columnRight = snap.isRightCorner ? bounds.right : splitX
                    let anchorBounds = PixelBounds(left: columnLeft,
                        top: snap.isBottomCorner ? splitY : bounds.top, right: columnRight,
                        bottom: snap.isBottomCorner ? bounds.bottom : splitY)
                    let quarterBounds = PixelBounds(left: columnLeft,
                        top: snap.isBottomCorner ? bounds.top : splitY, right: columnRight,
                        bottom: snap.isBottomCorner ? splitY : bounds.bottom)
                    let bandBounds = PixelBounds(left: snap.isRightCorner ? bounds.left : splitX,
                        top: bounds.top, right: snap.isRightCorner ? splitX : bounds.right, bottom: bounds.bottom)
                    guard contains(anchorConstraint, size: anchorBounds, scale: scale),
                          let bandFrames = allocateRegion(bandBounds, groups: bandGroups, constraints: constraints, scale: scale),
                          let quarterFrames = allocateRegion(quarterBounds, groups: quarterGroups, constraints: constraints, scale: scale) else { continue }
                    return bandFrames.merging(quarterFrames, uniquingKeysWith: { first, _ in first })
                        .merging([anchor: anchorBounds.rect(scale: scale)], uniquingKeysWith: { first, _ in first })
                }
            }
        }
        return nil
    }

    private static func regionShapes(_ peers: [WindowLayoutIdentity],
                                     constraints: [WindowLayoutIdentity: WindowLayoutSizeConstraint],
                                     heights: [CGFloat]) -> [[[WindowLayoutIdentity]]] {
        var shapes = (1...peers.count).map { grouped(peers, columns: $0) }
        for height in heights where height > 0 {
            if let shelf = shelfGroups(peers, constraints: constraints, height: height), !shapes.contains(shelf) {
                shapes.append(shelf)
            }
        }
        return shapes
    }

    private static func regionLimit(_ groups: [[WindowLayoutIdentity]],
                                    constraints: [WindowLayoutIdentity: WindowLayoutSizeConstraint], scale: CGFloat)
        -> (width: RangeLimit, height: RangeLimit)? {
        guard !groups.isEmpty, groups.allSatisfy({ !$0.isEmpty }) else { return nil }
        var widths: [RangeLimit] = []
        var heights: [RangeLimit] = []
        for group in groups {
            let values = group.compactMap { constraints[$0] }
            guard values.count == group.count else { return nil }
            widths.append(RangeLimit(minimum: values.map { pixels($0.minimum.width, scale: scale, up: true) }.max()!,
                                     maximum: values.map { pixels($0.maximum.width, scale: scale, up: false) }.min()!))
            heights.append(RangeLimit(minimum: values.reduce(0) { $0 + pixels($1.minimum.height, scale: scale, up: true) },
                                      maximum: values.reduce(0) { $0 + pixels($1.maximum.height, scale: scale, up: false) }))
        }
        return (RangeLimit(minimum: widths.reduce(0) { $0 + $1.minimum }, maximum: widths.reduce(0) { $0 + $1.maximum }),
                RangeLimit(minimum: heights.map(\.minimum).max()!, maximum: heights.map(\.maximum).min()!))
    }

    private static func allocateRegion(_ bounds: PixelBounds, groups: [[WindowLayoutIdentity]],
                                       constraints: [WindowLayoutIdentity: WindowLayoutSizeConstraint], scale: CGFloat)
        -> [WindowLayoutIdentity: CGRect]? {
        let widthLimits = groups.map { group -> RangeLimit in
            RangeLimit(minimum: group.map { pixels(constraints[$0]!.minimum.width, scale: scale, up: true) }.max()!,
                       maximum: group.map { pixels(constraints[$0]!.maximum.width, scale: scale, up: false) }.min()!)
        }
        guard let widths = balancedLengths(total: bounds.width, limits: widthLimits) else { return nil }
        var result: [WindowLayoutIdentity: CGRect] = [:]
        var x = bounds.left
        for (group, width) in zip(groups, widths) {
            let limits = group.map { range(constraints[$0]!.minimum.height, constraints[$0]!.maximum.height, scale: scale) }
            guard let heights = balancedLengths(total: bounds.height, limits: limits) else { return nil }
            var y = bounds.top
            for (id, height) in zip(group, heights) {
                let frame = PixelBounds(left: x, top: y, right: x + width, bottom: y + height)
                guard contains(constraints[id]!, size: frame, scale: scale) else { return nil }
                result[id] = frame.rect(scale: scale)
                y += height
            }
            x += width
        }
        return result
    }

    // Balanced populations preserve the existing order and layout whenever they can fit.
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

    // Greedily keep adjacent peers together while their height and shared width range permit it.
    // This bounded fallback is deliberately not an exhaustive arbitrary rectangle-packing solver.
    private static func shelfGroups(_ peers: [WindowLayoutIdentity],
                                    constraints: [WindowLayoutIdentity: WindowLayoutSizeConstraint],
                                    height: CGFloat) -> [[WindowLayoutIdentity]]? {
        var groups: [[WindowLayoutIdentity]] = []
        var group: [WindowLayoutIdentity] = []
        var usedHeight: CGFloat = 0
        var minimumWidth: CGFloat = 0
        var maximumWidth = CGFloat.greatestFiniteMagnitude
        for id in peers {
            guard let value = constraints[id], value.minimum.height <= height else { return nil }
            if !group.isEmpty && (usedHeight + value.minimum.height > height
                || max(minimumWidth, value.minimum.width) > min(maximumWidth, value.maximum.width)) {
                groups.append(group)
                group = []
                usedHeight = 0
                minimumWidth = 0
                maximumWidth = .greatestFiniteMagnitude
            }
            group.append(id)
            usedHeight += value.minimum.height
            minimumWidth = max(minimumWidth, value.minimum.width)
            maximumWidth = min(maximumWidth, value.maximum.width)
        }
        if !group.isEmpty { groups.append(group) }
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
