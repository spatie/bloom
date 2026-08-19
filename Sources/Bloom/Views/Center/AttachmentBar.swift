import SwiftUI

/// The row of chips above the text, and what happens when there are too many for one row.
///
/// Chips wrap rather than scroll sideways, because they are labels rather than a list: a name that
/// has scrolled off the left of a strip is a name nobody will find again. Past three rows the
/// whole block scrolls instead, so twenty attachments cost the transcript sixty points of height
/// rather than all of it.
struct AttachmentBar: View {
    var attachments: [PromptAttachment]
    var worktree: String
    var onOpen: @MainActor (PromptAttachment) -> Void
    var onRemove: @MainActor (PromptAttachment) -> Void
    /// The chip the pointer has settled on, or nil when it has left.
    var onHover: @MainActor (PromptAttachment?) -> Void

    /// Three rows of chips. Enough that the usual handful is never behind a scroller, and a hard
    /// stop so a drop of twenty files cannot push the conversation off the top of the window.
    private static let maxHeight: CGFloat = 82

    /// Starts at one row rather than at zero, so the first pass draws the chips at the height
    /// they are about to be measured at instead of flashing a collapsed bar.
    @State private var contentHeight = AttachmentChip.height

    var body: some View {
        ScrollView(.vertical) {
            ChipFlow(spacing: Metrics.spacingSmall, lineSpacing: Metrics.spacingSmall) {
                ForEach(attachments) { attachment in
                    AttachmentChip(
                        attachment: attachment,
                        worktree: worktree,
                        onOpen: { onOpen(attachment) },
                        onRemove: { onRemove(attachment) },
                        onHover: { onHover($0 ? attachment : nil) }
                    )
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(max(contentHeight, 0), Self.maxHeight))
        .scrollDisabled(contentHeight <= Self.maxHeight)
        .scrollBounceBehavior(.basedOnSize)
    }
}

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
