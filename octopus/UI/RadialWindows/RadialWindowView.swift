import SwiftUI

// Presentation adapted from Loop (Kai Azim), GPL-3.0, pinned reference in RadialWindowGeometry.swift.
struct RadialWindowView: View {
    @ObservedObject var model: RadialWindowModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<model.ringCount, id: \.self) { index in
                let step = 360 / Double(model.ringCount)
                slice(item: index < model.mainCount ? model.items[index] : nil,
                      start: Double(index) * step - step / 2, end: Double(index) * step + step / 2,
                      inner: RadialWindowGeometry.innerRadius, outer: RadialWindowGeometry.ringRadius,
                      selected: model.selection == .ring(index), more: index == model.mainCount)
            }
            if model.expanded {
                let span = Double(model.pageRange.count) * RadialWindowGeometry.overflowStep
                ForEach(Array(model.pageRange.enumerated()), id: \.element) { offset, index in
                    let start = 315 - span / 2 + Double(offset) * RadialWindowGeometry.overflowStep
                    slice(item: model.items[index], start: start, end: start + RadialWindowGeometry.overflowStep,
                          inner: RadialWindowGeometry.overflowInner, outer: RadialWindowGeometry.overflowOuter,
                          selected: model.selection == .overflow(index), more: false)
                }
            }
            Circle().fill(background).overlay(Circle().stroke(.primary.opacity(0.15)))
                .frame(width: RadialWindowGeometry.hubRadius * 2, height: RadialWindowGeometry.hubRadius * 2)
            VStack(spacing: 3) {
                if let item = model.selectedItem {
                    Text(item.applicationName).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(item.title).font(.caption2).lineLimit(2)
                } else if model.expanded {
                    Text("More").font(.caption.weight(.semibold))
                    Text("\(model.page + 1) / \(model.pageCount)").font(.caption2)
                    Text("Scroll for more").font(.system(size: 9))
                } else {
                    Text(model.message ?? "Cancel").font(.caption).lineLimit(3)
                }
            }
            .multilineTextAlignment(.center).frame(width: 80)
        }
        .frame(width: model.canvasSize, height: model.canvasSize)
    }

    private var background: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial)
    }

    private func slice(item: RadialWindowItem?, start: Double, end: Double, inner: CGFloat,
                       outer: CGFloat, selected: Bool, more: Bool) -> some View {
        let shape = RadialAnnularSector(start: start, end: end, inner: inner, outer: outer,
                                      gap: inner > RadialWindowGeometry.ringRadius ? 0.8 : RadialWindowGeometry.gap)
        return ZStack {
            shape.fill(background)
            shape.fill(Color.accentColor)
                .opacity(selected ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: selected)
            shape.stroke(.primary.opacity(0.15), lineWidth: 1)
            Group {
                if more { Image(systemName: "ellipsis.circle").resizable().scaledToFit() }
                else if let icon = item?.icon { Image(nsImage: icon).resizable().scaledToFit() }
                else { Image(systemName: "macwindow").resizable().scaledToFit() }
            }
            .frame(width: inner > RadialWindowGeometry.ringRadius ? 22 : 30,
                   height: inner > RadialWindowGeometry.ringRadius ? 22 : 30)
            .offset(RadialWindowGeometry.offset(angle: (start + end) / 2, radius: (inner + outer) / 2))
        }
        .opacity(item?.available == false ? 0.3 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(more ? "More windows" : "\(item?.applicationName ?? "") — \(item?.title ?? "")")
        .accessibilityValue(item?.available == false ? "Unavailable" : selected ? "Selected" : "")
    }
}

#Preview {
    RadialWindowView(model: RadialWindowModel(items: (1...15).map {
        RadialWindowItem(id: SidebarWindowID(pid: 0, windowID: UInt32($0)),
                         applicationName: "Example app", title: "Window \($0)", icon: NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil))
    })).padding(20)
}
