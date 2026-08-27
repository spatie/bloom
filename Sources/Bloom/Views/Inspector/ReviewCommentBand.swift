import SwiftUI
import BloomCore

/// One pending review comment, drawn in the diff under the line it is about.
///
/// The band is the second half of the annotation the tinted line starts, so it wears a paler
/// step of the same wash rather than a card of its own: a plate with a border here read as a
/// dialog interrupting the file. The content is capped at a prose measure while the wash runs
/// the full sheet, because the sheet can be thousands of points wide when a long line sets the
/// measure and a sentence stretched across it is unreadable.
///
/// It is also where a comment is rewritten. A note left on a line is one sentence, and one
/// sentence is the wrong size for a sheet: the text turns into a field in the place it was
/// reading, so the line it is about stays on screen next to it. What that field does with a key
/// is `ReviewCommentField`'s business, and what confirming means is `ReviewCommentEdit`'s.
struct ReviewCommentBandView: View {
    var placement: ReviewPlacement
    /// The sheet width every diff row is drawn at, so the band scrolls as part of the file.
    var width: CGFloat
    /// The text being typed, when this comment is the one being edited. Nil is the resting band.
    ///
    /// A binding handed in rather than state held here, because this row lives in a lazy stack
    /// and inside a view keyed by file path: scrolled away or glanced away from, it is destroyed,
    /// and a rewritten sentence held here would go with it. See `WorkspaceModel.reviewEdits`.
    var editing: Binding<String>?
    var onBeginEdit: @MainActor () -> Void
    var onCommitEdit: @MainActor () -> Void
    var onCancelEdit: @MainActor () -> Void
    var onRemove: @MainActor () -> Void

    @State private var isHovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter isHovered: where the pointer starts. Nothing in the app passes anything but
    ///   false; the snapshot gallery passes true because an offscreen render has no pointer, and
    ///   a control whose hovered state can never be photographed is a control nobody reviews.
    init(
        placement: ReviewPlacement,
        width: CGFloat,
        editing: Binding<String>? = nil,
        isHovered: Bool = false,
        onBeginEdit: @escaping @MainActor () -> Void,
        onCommitEdit: @escaping @MainActor () -> Void,
        onCancelEdit: @escaping @MainActor () -> Void,
        onRemove: @escaping @MainActor () -> Void
    ) {
        self.placement = placement
        self.width = width
        self.editing = editing
        self.onBeginEdit = onBeginEdit
        self.onCommitEdit = onCommitEdit
        self.onCancelEdit = onCancelEdit
        self.onRemove = onRemove
        _isHovered = State(initialValue: isHovered)
    }

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

                if let editing {
                    ReviewCommentField(
                        text: editing,
                        placeholder: "Say what this line should be",
                        onSubmit: onCommitEdit,
                        onCancel: onCancelEdit
                    )
                    ReviewCommentEditorButtons(
                        confirmTitle: "Save",
                        canConfirm: ReviewCommentEdit.canSubmit(editing.wrappedValue),
                        confirmHelp: "Save the comment (Return)",
                        onConfirm: onCommitEdit,
                        onCancel: onCancelEdit
                    )
                } else {
                    Text(placement.comment.body)
                        .font(Typo.body)
                        .foregroundStyle(Palette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)

            // Both controls are drawn at every moment, at their resting weight, and the pointer
            // only makes them plainer. The sidebar hides its row controls until the pointer
            // arrives because a column of archive boxes down a pane reads as an invitation; a
            // band is one object the reader is already looking at, its remove control has always
            // been visible here, and hiding the new one behind a hover would make rewriting a
            // comment a thing you have to already know about. Nothing moves either way, which is
            // the part of the sidebar's rule that matters: no size changes with the pointer.
            if editing == nil {
                HStack(spacing: Metrics.spacingSmall) {
                    control(
                        "pencil",
                        help: "Edit this comment",
                        label: "Edit the comment on \(chip)",
                        action: onBeginEdit
                    )
                    control(
                        "xmark",
                        help: "Remove this comment",
                        label: "Remove the comment on \(chip)",
                        action: onRemove
                    )
                }
                .animation(reduceMotion ? nil : Motion.hover, value: isHovered)
            }
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.spacingWide)
        .frame(width: width, alignment: .leading)
        .background(Palette.reviewBand)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review comment, \(chip)")
    }

    private func control(
        _ symbol: String,
        help: String,
        label: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Typo.micro)
                .imageScale(.small)
                .foregroundStyle(isHovered ? Palette.textPrimary : Palette.textSecondary)
                .frame(width: 18, height: 18)
                // A plate under each mark while the pointer is on the band, because the colour
                // step alone was almost invisible in a photograph of the two states side by side:
                // the resting mark is already a dark secondary in light appearance, so "plainer"
                // had nowhere to go. The plate says the marks are pressable, which is the thing a
                // reader who has never noticed them needs to be told.
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                        .fill(Palette.hover)
                        .opacity(isHovered ? 1 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
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
    var onCommit: @MainActor () -> Void
    var onCancel: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            ReviewCommentField(
                text: $text,
                placeholder: "Leave a comment",
                onSubmit: onCommit,
                onCancel: onCancel
            )

            ReviewCommentEditorButtons(
                confirmTitle: "Comment",
                canConfirm: ReviewCommentEdit.canSubmit(text),
                confirmHelp: "Add the comment (Return)",
                onConfirm: onCommit,
                onCancel: onCancel
            )
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.spacingWide)
        .frame(width: width, alignment: .leading)
        .background(Palette.reviewBand)
    }
}

/// Cancel and confirm, under whichever review comment editor is open.
///
/// One type for both, so the box that writes a comment and the box that rewrites one cannot drift
/// into two shapes. Only the word on the confirm button differs, and it differs because "Comment"
/// and "Save" are not the same promise.
struct ReviewCommentEditorButtons: View {
    var confirmTitle: String
    var canConfirm: Bool
    var confirmHelp: String
    var onConfirm: @MainActor () -> Void
    var onCancel: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            Spacer(minLength: 0)

            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Metrics.spacingWide)
                .padding(.vertical, Metrics.spacingSmall)
                .background(Palette.hover, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))

            Button(action: onConfirm) {
                HStack(spacing: Metrics.spacingSmall) {
                    Text(confirmTitle)
                    Image(systemName: "return")
                        .imageScale(.small)
                }
                .font(Typo.captionEmphasis)
                .foregroundStyle(Palette.selectedEmphasizedText)
                .padding(.horizontal, Metrics.spacingWide)
                .padding(.vertical, Metrics.spacingSmall)
                .background(
                    Palette.controlAccent.opacity(canConfirm ? 1 : 0.4),
                    in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canConfirm)
            .help(confirmHelp)
        }
        .frame(maxWidth: 560)
    }
}
