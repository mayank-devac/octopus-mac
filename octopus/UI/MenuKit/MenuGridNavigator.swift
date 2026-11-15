import Foundation

////////////////////
//// Arrow-key movement through a menu laid out as rows of items
/// ↑ ↓ move between rows and wrap like a native menu, keeping the column where
/// possible; ← → move within a row (a row of chips) and stop at its ends.
// With nothing focused, ↓ starts at the top and ↑ at the bottom.

enum MenuGridNavigator {
    static func move<ID: Equatable>(_ focus: ID?, _ key: MenuKey, in grid: [[ID]]) -> ID? {
        let rows = grid.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return nil }
        guard let focus, let row = rows.firstIndex(where: { $0.contains(focus) }),
              let column = rows[row].firstIndex(of: focus) else {
            return key == .up ? rows.last?.first : rows.first?.first
        }
        switch key {
        case .down:
            let next = rows[(row + 1) % rows.count]
            return next[min(column, next.count - 1)]
        case .up:
            let previous = rows[(row - 1 + rows.count) % rows.count]
            return previous[min(column, previous.count - 1)]
        case .left:
            return column > 0 ? rows[row][column - 1] : focus
        case .right:
            return column + 1 < rows[row].count ? rows[row][column + 1] : focus
        case .confirm, .cancel:
            return focus
        }
    }
}

//////////////////
