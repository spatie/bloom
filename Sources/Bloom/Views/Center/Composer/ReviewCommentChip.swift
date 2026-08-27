import SwiftUI
import BloomCore

/// One pending review comment, riding with the next message: `Widget.swift +34`.
///
/// A sibling of `AttachmentChip` and `SlashCommandChip`, built to the same measurements: the same
/// height, the same plate, the same leading slot that becomes the close control under the
/// pointer. The three sit in the same strip above the same box and are the same kind of object,
/// something the next turn carries that is not a word of the prompt.
///
/// Unlike those two it is not a token of the draft's own text. The comment lives in the store
/// until the message goes, so removing the chip deletes the comment rather than editing the
/// sentence, and the chips survive a relaunch the way the draft does.
struct ReviewCommentChip: View {
    var comment: ReviewComment
    var onRemove: @MainActor () -> Void
    /// Clicking the chip shows the comment where it was written, which is the file's diff.
    var onOpen: @MainActor () -> Void

    @State private var isHovered = false

    /// The same slot as the sibling chips, so a row holding all three kinds has one rhythm. Their
    /// constant rather than a third copy of its value.
    private static let slot: CGFloat = AttachmentChip.slot
    /// And the same ceiling on the name, which was written here as a bare 340 in the frame below.
    /// A comment's summary is the same kind of thing a plugin's name is: middle truncated, the
    /// half that says which one it is goes first.
    private static let maxNameWidth: CGFloat = SlashCommandChip.maxNameWidth

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            leading

            Text(ReviewCommentSummary.chip(for: comment))
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Self.maxNameWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Metrics.spacing)
        .frame(height: AttachmentChip.height)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .fill(isHovered ? Palette.hover : Palette.surfaceRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
        }
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        // The body is the part the chip has no room for, so it is the hover card's whole job.
        .help(comment.body)
        .contextMenu {
            Button("Show in the diff", action: onOpen)
            Divider()
            Button("Remove the comment", action: onRemove)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Review comment on \(ReviewCommentSummary.chip(for: comment))")
        .accessibilityValue(comment.body)
        .accessibilityAction(named: "Remove", onRemove)
        .accessibilityAction(named: "Show in the diff", onOpen)
    }

    /// The comment's mark, becoming the close control under the pointer. A real button, so Tab
    /// reaches it and Space presses it without a mouse.
    @ViewBuilder
    private var leading: some View {
        if isHovered {
            // The same control the other chips in this strip draw, out of the same numbers. It
            // was an `xmark.circle.fill`, whose X is a hole in the disc rather than a mark on it.
            // See `ChipRemoveMark`.
            ChipRemoveButton(diameter: Self.slot, label: "Remove the comment", action: onRemove)
        } else {
            Image(systemName: "text.bubble")
                .resizable()
                .scaledToFit()
                .frame(width: Self.slot, height: Self.slot)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)
        }
    }
}
