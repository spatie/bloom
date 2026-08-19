import SwiftUI

/// The preview card a transcript shows while the pointer rests on a file chip.
///
/// **Drawn here rather than beside the chip, and that is the whole difficulty.** The chips live in
/// rows inside a `LazyVStack` inside a `ScrollView`. A card put next to one of them is clipped by
/// the pane's edge in three directions out of four, and a chip near the bottom of a long
/// transcript would push its card off the window entirely. So the card is an overlay ON the scroll
/// view, at the pane's own level, and the chip only says where it is. `AttachmentChip.onPreview`
/// reports that in window coordinates, which is the one space a row twelve levels deep and this
/// view can both name.
///
/// It reads `host.request` and the enclosing list does not, which is what keeps a hover from
/// re-running a body that holds a `ForEach` over every row in the session.
///
/// Nothing about the file is loaded until a hover commits. `AttachmentCard` asks Quick Look for a
/// thumbnail when it appears and drops it when it goes, so a transcript with four hundred chips in
/// it holds no previews at all until the pointer settles on one, and holds exactly one after that.
struct FilePreviewOverlay: View {
    var host: FilePreviewHost

    /// Air between the chip and the card, and the least the card may come to the pane's edge.
    private static let gap: CGFloat = 6
    private static let margin = Metrics.gutter

    /// What the card is assumed to be before it has been measured, used for one layout pass only.
    /// It mirrors `AttachmentCard`'s own cap; being wrong about it costs a single invisible frame
    /// at zero opacity rather than a misplaced card, because the card is not shown until its real
    /// size is known.
    private static let assumedSize = CGSize(width: 520, height: 380)

    @State private var cardSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            card(in: geometry)
        }
        // The card never takes the pointer. It sits between the pointer and the chip it belongs
        // to, and a card that could be hovered would flicker itself away and back as the pointer
        // crossed the gap. `AttachmentCard` says the same thing about itself; this is the belt to
        // its braces, because here the card is over a whole pane of hoverable rows.
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func card(in geometry: GeometryProxy) -> some View {
        if let request = host.request {
            let pane = geometry.frame(in: .global)
            let chip = request.frame.offsetBy(dx: -pane.minX, dy: -pane.minY)
            let size = cardSize == .zero ? Self.assumedSize : cardSize
            let origin = place(chip: chip, card: size, in: pane.size)

            AttachmentCard(
                attachment: request.attachment,
                worktree: request.worktree,
                availableWidth: pane.width
            )
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
            .offset(x: origin.x, y: origin.y)
            // Hidden for the one pass between being built and being measured. After a 350ms
            // hover delay a single frame is not perceptible, and it is the alternative to
            // drawing the card in the wrong place and letting the reader watch it jump.
            .opacity(cardSize == .zero ? 0 : 1)
            // A different file is a different size, so the measurement has to be taken again
            // rather than the last card's size being reused to place this one.
            .onChange(of: request.attachment.path) { _, _ in cardSize = .zero }
        }
    }

    /// Where the card's top left corner goes, in the pane's own coordinates.
    ///
    /// Below the chip and aligned with its left edge when there is room, which is the position
    /// that reads as belonging to the chip. Every fallback from there is about staying inside the
    /// pane: above when there is no room below, and clamped into the margins in both axes when
    /// there is no room either way, because a card half outside the pane is clipped to nothing by
    /// the scroll view's own bounds.
    private func place(chip: CGRect, card: CGSize, in pane: CGSize) -> CGPoint {
        let below = chip.maxY + Self.gap
        let above = chip.minY - Self.gap - card.height

        let y: CGFloat = if below + card.height <= pane.height - Self.margin {
            below
        } else if above >= Self.margin {
            above
        } else {
            // Neither side fits, which is a pane shorter than the card. Pinned to the top and
            // clipped at the bottom rather than centred and clipped at both ends.
            max(Self.margin, min(below, pane.height - card.height - Self.margin))
        }

        let x = max(
            Self.margin,
            min(chip.minX, pane.width - card.width - Self.margin)
        )

        return CGPoint(x: x, y: y)
    }
}
