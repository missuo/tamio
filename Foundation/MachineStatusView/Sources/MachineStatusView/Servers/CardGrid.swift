//
//  CardGrid.swift
//  MachineStatusView
//
//  As many columns as cards of at least `minimumWidth` fit, sharing the row
//  between them, so no width is left over at the trailing edge. Not lazy: when
//  the width crosses into one more or one fewer column (the sidebar sliding
//  open, the window resized), the cards already there are only moved. A
//  LazyVGrid rebuilt its rows at that frame, and the slide stuttered.
//
//  The cards are all one height, whatever their width, so the grid measures
//  one of them, at a proposal that never changes so SwiftUI's cache answers,
//  instead of every card at every width the slide passes through.
//

import SwiftUI

public struct CardGrid: Layout {
    let minimumWidth: CGFloat
    let spacing: CGFloat
    /// The grid's width with the window's sidebar open. The column count is
    /// chosen for the narrower of it and the grid's width, so hiding the
    /// sidebar widens the cards instead of adding a column.
    let openWidth: CGFloat

    public init(minimumWidth: CGFloat, spacing: CGFloat, openWidth: CGFloat = .infinity) {
        self.minimumWidth = minimumWidth
        self.spacing = spacing
        self.openWidth = openWidth
    }

    public struct Cache {
        var rowHeight: CGFloat?
    }

    public func makeCache(subviews _: Subviews) -> Cache { Cache() }
    public func updateCache(_ cache: inout Cache, subviews _: Subviews) { cache.rowHeight = nil }

    private func columns(for width: CGFloat) -> (count: Int, width: CGFloat) {
        // Asked for its ideal size, the grid is proposed an infinite width,
        // and Int(.infinity) traps (#11): then, and for any width no row of
        // cards could have, one column of the narrowest cards.
        guard width.isFinite, width < 100_000 else { return (1, minimumWidth) }
        let count = max(1, Int((min(width, openWidth) + spacing) / (minimumWidth + spacing)))
        return (count, max(minimumWidth, (width - spacing * CGFloat(count - 1)) / CGFloat(count)))
    }

    private func rowHeight(_ subviews: Subviews, cache: inout Cache) -> CGFloat {
        if let height = cache.rowHeight { return height }
        let height = subviews.first?.sizeThatFits(ProposedViewSize(width: minimumWidth, height: nil)).height ?? 0
        cache.rowHeight = height
        return height
    }

    private func rowCount(_ subviews: Subviews, columns: Int) -> Int {
        (subviews.count + columns - 1) / columns
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let (count, column) = columns(for: proposal.width ?? minimumWidth)
        // The width the columns add up to: the proposal's when it is a real
        // one, else the one column's.
        let width = proposal.width.map { $0.isFinite && $0 < 100_000 ? $0 : column } ?? column
        let rows = rowCount(subviews, columns: count)
        let height = rowHeight(subviews, cache: &cache)
        return CGSize(width: width, height: CGFloat(rows) * height + spacing * CGFloat(max(0, rows - 1)))
    }

    public func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let (count, column) = columns(for: bounds.width)
        let height = rowHeight(subviews, cache: &cache)
        for (index, subview) in subviews.enumerated() {
            let row = index / count
            let x = bounds.minX + CGFloat(index % count) * (column + spacing)
            let y = bounds.minY + CGFloat(row) * (height + spacing)
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: column, height: height))
        }
    }
}
