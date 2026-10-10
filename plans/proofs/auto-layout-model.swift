// Planning prototype only. No AX calls, app windows, or production imports.
// The runner prepends Rectangle's pinned, unmodified GridTiling.swift.
import Foundation

indirect enum ModelNode {
    case window(Int, Int, Int) // identity, minimum width/height in backing pixels
    case group(GridTiling.Direction, [ModelNode])

    var minimum: (Int, Int) {
        switch self {
        case .window(_, let w, let h): return (w, h)
        case .group(let direction, let children):
            let sizes = children.map(\.minimum)
            if direction == .columns {
                return (sizes.map { $0.0 }.reduce(0, +), sizes.map { $0.1 }.max() ?? 0)
            }
            return (sizes.map { $0.0 }.max() ?? 0, sizes.map { $0.1 }.reduce(0, +))
        }
    }

    var ids: [Int] {
        switch self {
        case .window(let id, _, _): return [id]
        case .group(_, let children): return children.flatMap(\.ids)
        }
    }
}

func frames(_ node: ModelNode, _ bounds: CGRect) -> [Int: CGRect]? {
    guard bounds.width > 0, bounds.height > 0,
          bounds.width >= CGFloat(node.minimum.0), bounds.height >= CGFloat(node.minimum.1) else { return nil }
    switch node {
    case .window(let id, _, _): return [id: bounds]
    case .group(let direction, let children):
        guard !children.isEmpty else { return nil }
        let axisExtent = Int(direction == .columns ? bounds.width : bounds.height)
        let constraints = children.map { child -> GridTiling.Constraint in
            let minimum = direction == .columns ? child.minimum.0 : child.minimum.1
            return .resizable(minimum: minimum, maximum: axisExtent)
        }
        // Execute the real upstream constraint allocator, not a reimplementation.
        let allocation = GridTiling.balancedBandLengths(totalPixels: axisExtent, constraints: constraints)
        guard allocation.feasible else { return nil }
        let areas = GridTiling.backingBandRects(bounds: .init(bounds), lengths: allocation.lengths, direction: direction)
        var result: [Int: CGRect] = [:]
        for (child, area) in zip(children, areas) {
            guard let childrenFrames = frames(child, area) else { return nil }
            for (id, rect) in childrenFrames {
                guard result[id] == nil else { return nil }
                result[id] = rect
            }
        }
        return result
    }
}

func insert(_ newcomer: ModelNode, after id: Int, into node: ModelNode) -> ModelNode {
    switch node {
    case .window(let existing, _, _) where existing == id:
        return .group(.columns, [node, newcomer])
    case .window: return node
    case .group(let direction, let children):
        if let index = children.firstIndex(where: {
            if case .window(let existing, _, _) = $0 { return existing == id }; return false
        }) {
            var next = children; next.insert(newcomer, at: index + 1)
            return .group(direction, next)
        }
        return .group(direction, children.map { insert(newcomer, after: id, into: $0) })
    }
}

func removing(_ id: Int, from node: ModelNode) -> ModelNode? {
    switch node {
    case .window(let existing, _, _): return existing == id ? nil : node
    case .group(let direction, let children):
        let remaining = children.compactMap { removing(id, from: $0) }
        if remaining.isEmpty { return nil }
        if remaining.count == 1 { return remaining[0] }
        return .group(direction, remaining)
    }
}

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}
func verify(_ node: ModelNode, bounds: CGRect) {
    guard let result = frames(node, bounds) else { fatalError("Unexpected infeasible fixture") }
    check(Set(result.keys) == Set(node.ids), "Missing or duplicate window")
    check(result.count == node.ids.count, "Duplicated input identity")
    for (id, rect) in result {
        check(bounds.contains(rect), "Off-display frame \(id)")
        check(rect.width > 0 && rect.height > 0, "Empty frame")
        check(rect.minX.rounded() == rect.minX && rect.minY.rounded() == rect.minY
              && rect.width.rounded() == rect.width && rect.height.rounded() == rect.height, "Fractional pixel")
    }
    let values = Array(result.values)
    for a in values.indices { for b in values.indices where a < b {
        let intersection = values[a].intersection(values[b])
        check(intersection.isNull || intersection.width * intersection.height == 0, "Overlap")
    } }
    check(values.reduce(CGFloat(0)) { $0 + $1.width * $1.height } == bounds.width * bounds.height, "Lost pixels")
    check(frames(node, bounds) == result, "Nondeterministic layout")
}

func leaf(_ id: Int) -> ModelNode { .window(id, 320, 200) }
let bounds = CGRect(x: -1729, y: -413, width: 1729, height: 1001)
let pair = ModelNode.group(.columns, [leaf(1), leaf(2)])
verify(pair, bounds: bounds)
let inserted = insert(leaf(3), after: 1, into: pair)
check(inserted.ids == [1, 3, 2], "New window must join MRU's parent, after MRU")
verify(inserted, bounds: bounds)
let thirdFrames = frames(inserted, bounds)!
check(Set(thirdFrames.values.map { Int($0.width) }).isSubset(of: [576, 577]), "Expected thirds with exact remainder")
check(removing(3, from: inserted)!.ids == [1, 2], "Close did not remove exact identity")
verify(removing(3, from: inserted)!, bounds: bounds)

// Explicit half snap locks its boundary; solve peers in the other half.
for count in 2...5 {
    let peers = ModelNode.group(.rows, (2...count).map(leaf))
    let half = bounds.minX + floor(bounds.width / 2)
    let anchor = CGRect(x: bounds.minX, y: bounds.minY, width: half - bounds.minX, height: bounds.height)
    let remainder = CGRect(x: half, y: bounds.minY, width: bounds.maxX - half, height: bounds.height)
    verify(leaf(1), bounds: anchor)
    verify(peers, bounds: remainder)
    check(anchor.intersection(remainder).width == 0, "Reserved snap overlaps peer region")
}

// Exercise both axes, odd/even dimensions, negative origins, and backing scales.
for scale in [1, 2] {
    for count in 1...12 {
        for direction in [GridTiling.Direction.rows, .columns] {
            let extent = direction == .columns ? 320 * count + 17 : 200 * count + 19
            let rect = CGRect(x: -721 * scale, y: 39 * scale,
                              width: direction == .columns ? extent * scale : 1401 * scale,
                              height: direction == .rows ? extent * scale : 1001 * scale)
            let children = (1...count).map { ModelNode.window($0, 320 * scale, 200 * scale) }
            verify(.group(direction, children), bounds: rect)
        }
    }
}
let minimums = GridTiling.balancedBandLengths(totalPixels: 1001, constraints: [
    .resizable(minimum: 700, maximum: 1001), .resizable(minimum: 200, maximum: 1001)])
check(minimums.feasible && minimums.lengths == [700, 301], "Known minimum ignored")
check(!GridTiling.balancedBandLengths(totalPixels: 800, constraints: [
    .resizable(minimum: 500, maximum: 800), .resizable(minimum: 500, maximum: 800)]).feasible, "Shortage not detected")
check(frames(.group(.columns, [leaf(1), leaf(2), leaf(3)]), CGRect(x: 0, y: 0, width: 800, height: 600)) == nil,
      "Must reject infeasible plan before writes")
check(frames(.group(.columns, [leaf(1), leaf(1)]), bounds) == nil, "Duplicate input identities accepted")
check(frames(pair, .zero) == nil, "Invalid work area accepted")
print("PASS: \(checks) deterministic geometry assertions; real Rectangle allocator + proposed tree adapter")
print("NOT TESTED: AX writes, notifications, focus, native Desktops, live windows, rollback, third-party managers")
