import SwiftUI

/// Left to right, wrapping onto the next line, which is the one thing `HStack` cannot do and
/// `LazyVGrid` can only fake with columns of a fixed width.
struct ChipFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(for: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let placements = frames(for: subviews, width: bounds.width).frames
        for (view, frame) in zip(subviews, placements) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    /// One pass over the subviews at their natural size. A chip caps its own width, so nothing
    /// here has to decide how wide a name is allowed to be.
    private func frames(for subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            // Never wrap the first chip of a row: at a width narrower than one chip it would wrap
            // forever, and a truncated chip is better than an empty line above it.
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }

        return (frames, CGSize(width: widest, height: y + rowHeight))
    }
}
