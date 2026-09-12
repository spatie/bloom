import SwiftUI

/// Measures the content at its capped width without expanding short messages to that cap.
public struct CappedWidth: Layout {
    public var width: CGFloat

    public init(width: CGFloat) { self.width = width }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        // The pane can be narrower than the cap, and a bubble wider than the pane is worse than a
        // bubble that never reaches its cap.
        let limit = min(proposal.width ?? width, width)
        return subview.sizeThatFits(ProposedViewSize(width: limit, height: proposal.height))
    }

    public func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size)
        )
    }
}
