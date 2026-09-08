import SwiftUI

/// Measures every cell at its share of the reading column before choosing each row's height.
/// An unconstrained grid in a horizontal scroll view instead measures whole, unwrapped sentences.
struct MarkdownTableLayout: Layout {
    var columns: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposedWidth(proposal.width)
        return CGSize(width: width, height: rowHeights(width: width, subviews: subviews).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard columns > 0 else { return }
        let heights = rowHeights(width: bounds.width, subviews: subviews)
        let columnWidth = bounds.width / CGFloat(columns)
        var y = bounds.minY
        for index in subviews.indices {
            let row = index / columns
            let column = index % columns
            subviews[index].place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * columnWidth, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: columnWidth, height: heights[row])
            )
            if column == columns - 1 { y += heights[row] }
        }
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        guard columns > 0 else { return [] }
        let proposal = ProposedViewSize(width: width / CGFloat(columns), height: nil)
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + columns - 1) / columns)
        for index in subviews.indices {
            let height = subviews[index].sizeThatFits(proposal).height
            heights[index / columns] = max(heights[index / columns], ceil(height))
        }
        return heights
    }

    private func proposedWidth(_ width: CGFloat?) -> CGFloat {
        guard let width, width.isFinite else { return TranscriptLayout.proseMeasure }
        return max(0, width)
    }
}
