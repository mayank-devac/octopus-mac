import AppKit
import SwiftUI

// Circular placement follows Kai Azim's Loop RadialLayout / radial indicator:
// https://github.com/mrkai77/Loop/tree/573ace3071641bbe002527ccfc0811842300ccba/Loop/Window%20Action%20Indicators/Radial%20Menu
// GPL-3.0. Annular sectors follow Mayank's RadialWindowMenu reference.
enum RadialWindowGeometry {
    static let hubRadius: CGFloat = 46
    static let innerRadius: CGFloat = 62
    static let ringRadius: CGFloat = 150
    static let overflowInner: CGFloat = 156
    static let overflowOuter: CGFloat = 214
    static let overflowStep = 22.0
    static let pageSize = 6
    static let gap = 1.6
    static let pointerThreshold: CGFloat = 6
    static let statusCanvas: CGFloat = hubRadius * 2 + 20

    enum Hit: Equatable { case none, ring(Int), overflow(Int) }

    static func canvas(overflow: Bool) -> CGFloat { (overflow ? overflowOuter : ringRadius) * 2 + 20 }

    // Status circles stay at the cursor even near an edge; only the full ring is clamped.
    static func statusFrame(at point: CGPoint) -> CGRect {
        CGRect(x: point.x - statusCanvas / 2, y: point.y - statusCanvas / 2,
               width: statusCanvas, height: statusCanvas)
    }

    static func offset(angle: Double, radius: CGFloat) -> CGSize {
        let radians = angle * .pi / 180
        return CGSize(width: sin(radians) * radius, height: -cos(radians) * radius)
    }

    static func localOffset(pointer: CGPoint, centre: CGPoint) -> CGVector {
        CGVector(dx: pointer.x - centre.x, dy: centre.y - pointer.y)
    }

    static func panelFrame(at point: CGPoint, available: CGRect, overflow: Bool) -> CGRect? {
        let size = canvas(overflow: overflow)
        let bounds = available.insetBy(dx: 12, dy: 12)
        guard bounds.width >= size, bounds.height >= size else { return nil }
        return CGRect(x: min(max(point.x - size / 2, bounds.minX), bounds.maxX - size),
                      y: min(max(point.y - size / 2, bounds.minY), bounds.maxY - size), width: size, height: size)
    }

    static func hit(_ offset: CGVector, ringCount: Int, overflowCount: Int, expanded: Bool) -> Hit {
        guard ringCount > 0 else { return .none }
        let distance = hypot(offset.dx, offset.dy)
        var angle = atan2(offset.dx, -offset.dy) * 180 / .pi
        if angle < 0 { angle += 360 }
        if expanded, overflowCount > 0, distance >= overflowInner, distance <= overflowOuter {
            let delta = signedAngle(angle - 315)
            let span = Double(overflowCount) * overflowStep
            let position = delta + span / 2
            guard position >= 0, position < span else { return .none }
            let index = Int(position / overflowStep)
            let within = position - Double(index) * overflowStep
            return within >= 0.8 && within <= overflowStep - 0.8 ? .overflow(index) : .none
        }
        guard distance >= innerRadius, distance <= ringRadius else { return .none }
        let step = 360 / Double(ringCount)
        let index = Int((angle + step / 2).truncatingRemainder(dividingBy: 360) / step)
        // The visible gaps are cancellation regions too.
        return abs(signedAngle(angle - Double(index) * step)) <= step / 2 - gap ? .ring(index) : .none
    }

    private static func signedAngle(_ degrees: Double) -> Double {
        let value = (degrees + 540).truncatingRemainder(dividingBy: 360)
        return value - 180
    }
}

struct RadialAnnularSector: Shape {
    let start: Double
    let end: Double
    let inner: CGFloat
    let outer: CGFloat
    var gap: Double = RadialWindowGeometry.gap

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(center: centre, radius: outer, startAngle: .degrees(start + gap - 90),
                    endAngle: .degrees(end - gap - 90), clockwise: false)
        path.addArc(center: centre, radius: inner, startAngle: .degrees(end - gap - 90),
                    endAngle: .degrees(start + gap - 90), clockwise: true)
        path.closeSubpath()
        return path
    }
}
