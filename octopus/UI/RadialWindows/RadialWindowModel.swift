import AppKit
import Combine

struct RadialWindowItem: Identifiable {
    let id: SidebarWindowID
    let applicationName: String
    let title: String
    let icon: NSImage?
    var available = true
}

enum RadialWindowSelection: Equatable {
    case none, ring(Int), overflow(Int)
}

@MainActor
final class RadialWindowModel: ObservableObject {
    enum Command: Equatable { case previous, next, enter, previousPage, nextPage }
    @Published private(set) var items: [RadialWindowItem] = []
    @Published private(set) var selection = RadialWindowSelection.none
    @Published private(set) var expanded = false
    @Published private(set) var page = 0
    @Published var message: String? = "Loading windows…"
    private var pointerAnchor: CGPoint
    private var pointerArmed = false
    private var lastPointer: CGPoint

    init(items: [RadialWindowItem]? = nil, pointer: CGPoint = .zero) {
        pointerAnchor = pointer
        lastPointer = pointer
        if let items { load(items) }
    }

    var hasOverflow: Bool { items.count > 8 }
    var canvasSize: CGFloat {
        items.isEmpty ? RadialWindowGeometry.statusCanvas : RadialWindowGeometry.canvas(overflow: hasOverflow)
    }
    var ringCount: Int { min(items.count, 8) }
    var mainCount: Int { hasOverflow ? 7 : items.count }
    var overflowCount: Int { hasOverflow ? items.count - 7 : 0 }
    var pageCount: Int { max(1, (overflowCount + RadialWindowGeometry.pageSize - 1) / RadialWindowGeometry.pageSize) }
    var pageRange: Range<Int> {
        let start = min(items.count, mainCount + page * RadialWindowGeometry.pageSize)
        return start..<min(items.count, start + (hasOverflow ? RadialWindowGeometry.pageSize : 0))
    }
    var selectedItem: RadialWindowItem? {
        let index: Int
        switch selection {
        case .none: return nil
        case .ring(let value): guard value < mainCount else { return nil }; index = value
        case .overflow(let value): index = value
        }
        guard items.indices.contains(index), items[index].available else { return nil }
        return items[index]
    }
    var selectsMore: Bool { hasOverflow && selection == .ring(7) }

    func load(_ items: [RadialWindowItem]) {
        self.items = items
        message = items.isEmpty ? "No open windows" : nil
        selection = .none
        page = 0
        expanded = false
    }

    // Preserve all slot/page positions; a disappearing window is never replaced mid-gesture.
    func reconcile(availableIDs: Set<SidebarWindowID>) {
        items = items.map { item in var next = item; next.available = availableIDs.contains(item.id); return next }
        if !selectsMore && selectedItem == nil { selection = .none }
    }

    func updatePointer(_ point: CGPoint, centre: CGPoint) {
        guard point != lastPointer else { return }
        lastPointer = point
        if !pointerArmed {
            guard hypot(point.x - pointerAnchor.x, point.y - pointerAnchor.y) >= RadialWindowGeometry.pointerThreshold else { return }
            pointerArmed = true
        }
        let offset = RadialWindowGeometry.localOffset(pointer: point, centre: centre)
        let distance = hypot(offset.dx, offset.dy)
        let hit = RadialWindowGeometry.hit(offset, ringCount: ringCount, overflowCount: pageRange.count, expanded: expanded)
        switch hit {
        case .ring(let index):
            expanded = hasOverflow && index == 7
            selection = .ring(index)
        case .overflow(let index): selection = .overflow(pageRange.lowerBound + index)
        case .none:
            selection = .none
            if distance < RadialWindowGeometry.innerRadius || distance > RadialWindowGeometry.overflowOuter + 10 { expanded = false }
        }
        if !selectsMore && selectedItem == nil { selection = .none }
    }

    func changePage(_ direction: Int) {
        guard expanded else { return }
        let next = min(max(page + direction, 0), pageCount - 1)
        guard next != page else { return }
        page = next
        selection = .none
        pointerAnchor = lastPointer
        pointerArmed = false
    }

    func navigate(_ command: Command) {
        guard !items.isEmpty else { return }
        switch command {
        case .previousPage: changePage(-1); return
        case .nextPage: changePage(1); return
        case .enter:
            if selectsMore { expanded = true; selection = .overflow(pageRange.lowerBound) }
            return
        case .previous, .next: break
        }
        let direction = command == .next ? 1 : -1
        switch selection {
        case .none: selection = .ring(direction > 0 ? 0 : max(0, ringCount - 1))
        case .ring(let index):
            if hasOverflow && index == 7 && direction > 0 {
                selection = .overflow(pageRange.lowerBound)
            } else if ringCount > 0 {
                selection = .ring((index + direction + ringCount) % ringCount)
            }
        case .overflow(let index):
            let next = index + direction
            if next < 7 { selection = .ring(7) }
            else if next < items.count { page = (next - 7) / RadialWindowGeometry.pageSize; selection = .overflow(next) }
        }
        if case .overflow = selection { expanded = true }
        else { expanded = selectsMore }
    }
}
