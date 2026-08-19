import SwiftUI

/// The card that floats over the composer while the pointer rests on a chip.
///
/// It uses `MenuPanel`, the same card the slash and mention menus sit in, so the three things that
/// can appear above the composer are one material rather than three. It takes no clicks: the
/// pointer stays on the chip the whole time it is up, and a card that could be hovered would
/// flicker as the pointer crossed the gap between the two.
///
/// Sized to the pane rather than to a fixed rectangle. Conductor draws its preview at 850 by 640,
/// which is wider than a Bloom centre column that has been split in two, and a card that hangs
/// over the inspector to show a thumbnail is not showing it in the composer at all.
/// The card, or nothing, as one view.
///
/// The nil case is handled in here rather than with an `if let` at the call site, and that is not
/// a style choice. An explicit `alignmentGuide` is what lifts the card above the composer, and a
/// guide set on a view inside an `if` in an overlay's builder is not honoured: the card was drawn
/// over the composer instead of above it, clipped by the bottom of the window. Wrapping the
/// condition in a view of its own, exactly as `ComposerMenuOverlay` does, is what makes the guide
/// take effect.
struct AttachmentCardOverlay: View {
    var attachment: PromptAttachment?
    var worktree: String
    var availableWidth: CGFloat

    var body: some View {
        if let attachment {
            AttachmentCard(
                attachment: attachment, worktree: worktree, availableWidth: availableWidth
            )
        }
    }
}

struct AttachmentCard: View {
    var attachment: PromptAttachment
    var worktree: String
    /// What the composer has to give, which is what the card may take.
    var availableWidth: CGFloat

    /// Big enough that a screenshot of a window is readable, and no bigger: the card sits over the
    /// conversation the reader is answering, so it borrows that space rather than owning it.
    private static let maxWidth: CGFloat = 520
    private static let maxHeight: CGFloat = 380

    var body: some View {
        MenuPanel {
            VStack(alignment: .leading, spacing: 0) {
                AttachmentPreview(url: url, maxWidth: width, maxHeight: Self.maxHeight)
                    .frame(maxWidth: .infinity)
                    .padding(Metrics.spacingWide)

                Hairline()

                HStack(spacing: Metrics.spacingSmall) {
                    Text(attachment.path)
                        .font(Typo.codeSmall)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)

                    Spacer(minLength: Metrics.spacing)

                    if let size {
                        Text(size)
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                .padding(.horizontal, Metrics.spacingWide)
                .padding(.vertical, Metrics.spacingSmall)
            }
        }
        .frame(maxWidth: width + Metrics.spacingWide * 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var url: URL { attachment.url(in: worktree) }

    private var width: CGFloat {
        max(min(availableWidth - Metrics.gutter * 2, Self.maxWidth), 160)
    }

    private var size: String? {
        let bytes = attachment.byteCount > 0
            ? attachment.byteCount
            : AttachmentFiles.byteCount(of: url.path)
        guard bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
