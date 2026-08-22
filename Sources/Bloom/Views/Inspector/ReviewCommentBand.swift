import SwiftUI
import BloomCore

/// One pending review comment, drawn in the diff under the line it is about.
///
/// The band is the second half of the annotation the tinted line starts, so it wears a paler
/// step of the same wash rather than a card of its own: a plate with a border here read as a
/// dialog interrupting the file. The content is capped at a prose measure while the wash runs
/// the full sheet, because the sheet can be thousands of points wide when a long line sets the
/// measure and a sentence stretched across it is unreadable.
struct ReviewCommentBandView: View {
    var placement: ReviewPlacement
    /// The sheet width every diff row is drawn at, so the band scrolls as part of the file.
    var width: CGFloat
    var onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
            Image(systemName: "text.bubble")
                .font(Typo.micro)
                .imageScale(.small)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                if let note {
                    Text(note)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .italic()
                }
                Text(placement.comment.body)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 560, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(Typo.micro)
                    .imageScale(.small)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this comment")
            .accessibilityLabel("Remove the comment on \(chip)")
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.spacingWide)
        .frame(width: width, alignment: .leading)
        .background(Palette.reviewBand)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review comment, \(chip)")
    }

    private var chip: String {
        ReviewCommentSummary.chip(for: placement.comment)
    }

    /// Placement's honesty, said in the band rather than left for the payload to reveal. Nil for
    /// a comment sitting exactly where it was written, which is the only quiet case.
    private var note: String? {
        switch placement.status {
        case .placed(_, moved: false):
            return nil
        case .placed(let spot, moved: true):
            return "Moved here from line \(placement.comment.anchor.line); now line \(spot.line)."
        case .hidden(let line):
            return "\(chip): the line is now line \(line), which this diff does not show."
        case .outdated:
            return "\(chip): the line has changed or is gone. "
                + "The comment will be sent with the code as it looked when it was written."
        }
    }
}

/// The inline editor the gutter `+` opens: a field, Cancel, and Comment.
///
/// The text lives on the diff view rather than in here, because this row sits in a lazy stack:
/// scrolled far enough away it is destroyed, and a half-written comment must not go with it.
struct ReviewCommentEditorView: View {
    @Binding var text: String
    var width: CGFloat
    var onCommit: () -> Void
    var onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            TextField("Leave a comment", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit(onCommit)
                .padding(Metrics.spacing)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.corner))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.corner)
                        .strokeBorder(isFocused ? Palette.focusRing : Palette.border)
                )

            HStack(spacing: Metrics.spacing) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Metrics.spacingWide)
                    .padding(.vertical, Metrics.spacingSmall)
                    .background(Palette.hover, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))

                Button(action: onCommit) {
                    HStack(spacing: Metrics.spacingSmall) {
                        Text("Comment")
                        Image(systemName: "return")
                            .imageScale(.small)
                    }
                    .font(Typo.captionEmphasis)
                    .foregroundStyle(Palette.textInverted)
                    .padding(.horizontal, Metrics.spacingWide)
                    .padding(.vertical, Metrics.spacingSmall)
                    .background(
                        Palette.accentFill.opacity(canCommit ? 1 : 0.4),
                        in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canCommit)
                .help("Add the comment (Return)")
            }
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.spacingWide)
        .frame(width: width, alignment: .leading)
        .background(Palette.reviewBand)
        // Escape closes this editor and nothing else: `onExitCommand` only fires while the field
        // has focus, so the pane's own Escape behaviour is untouched the rest of the time.
        .onExitCommand(perform: onCancel)
        .onAppear { isFocused = true }
    }

    private var canCommit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
