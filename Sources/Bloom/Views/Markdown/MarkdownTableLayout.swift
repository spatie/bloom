import SwiftUI

/// Measures every cell at its share of the reading column before choosing each row's height.
/// An unconstrained grid in a horizontal scroll view instead measures whole, unwrapped sentences.
struct MarkdownTableLayout: Layout {
    var columns: Int

    /// Row heights by width. SwiftUI asks the same few widths dozens of times, 1,585 asks for thirty
    /// tables when a chat reopened, which held the main thread 26 seconds. SwiftUI empties it when
    /// the cells change.
    struct Cache {
        var heights: [CGFloat: [CGFloat]] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposedWidth(proposal.width)
        // An HStack ranking flexibility asks at width zero and reads only the width back. Measuring
        // every cell there wrapped each character onto its own line, 830 times in one reopen.
        guard width > 0 else { return .zero }
        return CGSize(width: width, height: rowHeights(width: width, subviews: subviews, cache: &cache).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard columns > 0 else { return }
        let heights = rowHeights(width: bounds.width, subviews: subviews, cache: &cache)
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

    // The default merges the cells' guides by placing them in a zero rect first, which measured
    // every cell a character per line for each table a stack aligned. A grid aligns by its edges.
    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout Cache
    ) -> CGFloat? { nil }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout Cache
    ) -> CGFloat? { nil }

    private func rowHeights(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGFloat] {
        if let known = cache.heights[width] { return known }
        guard columns > 0 else { return [] }
        let proposal = ProposedViewSize(width: width / CGFloat(columns), height: nil)
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + columns - 1) / columns)
        for index in subviews.indices {
            let height = subviews[index].sizeThatFits(proposal).height
            heights[index / columns] = max(heights[index / columns], ceil(height))
        }
        cache.heights[width] = heights
        return heights
    }

    private func proposedWidth(_ width: CGFloat?) -> CGFloat {
        guard let width, width.isFinite else { return TranscriptLayout.proseMeasure }
        return max(0, width)
    }
}
