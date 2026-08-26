import SwiftUI
import UniformTypeIdentifiers
import BloomCore

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
    /// conversation the reader is answering, so it borrows that space rather than owning it. The
    /// box every card over the centre pane takes, which is `HoverCardWidth.ceiling`.
    private static var maxWidth: CGFloat { HoverCardWidth.ceiling }
    private static let maxHeight: CGFloat = 380

    var body: some View {
        MenuPanel {
            VStack(alignment: .leading, spacing: 0) {
                // The same air on all four sides. It was `Metrics.spacingWide` here and then a
                // hairline and a caption row underneath, which measured ten points above the
                // preview and forty six below it: the caption was reading as the bottom half of
                // the padding rather than as a label, and the preview sat off centre in its own
                // card. `Metrics.spacing` above and below with the caption's own inset matching
                // puts the block in the middle of what surrounds it.
                AttachmentPreview(url: url, maxWidth: width, maxHeight: Self.maxHeight)
                    .frame(maxWidth: .infinity, alignment: isImage ? .center : .leading)
                    .padding(Metrics.inset)

                // A picture answers the question the hover asked, so a path and a byte count
                // under it are furniture. Everything else leaves "which file is this" open,
                // and for those the path is the useful half.
                if !isImage {
                    Hairline()

                    Text(attachment.path)
                        .font(Typo.codeSmall)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Metrics.inset)
                        .padding(.vertical, Metrics.spacing)
                }
            }
        }
        .frame(maxWidth: width + Metrics.inset * 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var url: URL { attachment.url(in: worktree) }

    private var width: CGFloat {
        max(min(availableWidth - Metrics.gutter * 2, Self.maxWidth), 160)
    }

    /// Asked of the type rather than of a list of extensions, so HEIC and WebP come along
    /// without being named. A PDF and a movie do not conform to `.image`, which is where the
    /// line wants to be: a PDF's first page is often a cover and a poster frame says even less.
    private var isImage: Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}
