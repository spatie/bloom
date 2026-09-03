import SwiftUI
import BloomCore

/// The box a few lines of a file are edited in, drawn in the diff where those lines are.
///
/// The whole point of editing here rather than in Edit mode is that the reader does not have to
/// leave the thing they noticed: a typo, a renamed variable, a comment. So the band sits directly
/// under the lines it stands for, wears the same wash the review bands do, and carries the two
/// controls that matter and nothing else.
///
/// **The text is a binding handed in, never state held here.** This row sits in a lazy stack
/// inside a view keyed by file path: scrolled away from or glanced away from, it is destroyed, and
/// a half-finished edit held here would go with it. See `DiffEditSession`.
///
/// The editor is `SourceEditor`, the same `NSTextView` Edit mode and the settings scripts use, so
/// there is one syntax theme and one set of editing behaviours in the app rather than a third. It
/// is a scroll view of its own inside the diff's scroll view, which `ScriptEditor` already does
/// inside a form for the same reason: it is the only way indented code keeps its shape instead of
/// wrapping.
struct DiffEditBandView: View {
    var region: DiffEditRegion
    @Binding var text: String
    var language: Language
    /// Whether the file has moved under this box, or a save has been refused. What it says, and
    /// which of the two it is, are both read off it: a save that would not go through is the one
    /// moment in this box a reader must not miss, so it is drawn in the colour of a failure,
    /// while a file that has merely moved on is a caution.
    var status: DiffEditSession.Status
    /// The sheet width every diff row is drawn at, so the band scrolls as part of the file.
    var width: CGFloat
    var onSave: @MainActor () -> Void
    var onCancel: @MainActor () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Where the box stops growing and starts scrolling, in lines. Eighteen is `ScriptEditor`'s
    /// ceiling and the same argument holds: past that the band is taller than the pane and the
    /// code it is about has left the screen.
    private static let maximumLines = 18
    /// Never less than three, so a one line fix still has somewhere to put a second line.
    private static let minimumLines = 3
    /// The text container's inset above and below, which `SourceEditor` sets at six each.
    private static let verticalPadding: CGFloat = 12
    /// A prose measure for code: wide enough for a long line, and far short of a sheet that can be
    /// thousands of points across when one minified line sets the diff's width.
    private static let measure: CGFloat = 760

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            header

            SourceEditor(
                text: $text,
                language: language,
                colorScheme: colorScheme,
                ground: Palette.surface
            )
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .strokeBorder(Palette.border, lineWidth: Metrics.outline)
            }

            if let warning = status.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.caption)
                    .foregroundStyle(isRefused ? Palette.negative : Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            buttons
        }
        .frame(maxWidth: Self.measure, alignment: .leading)
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.spacingWide)
        .frame(width: width, alignment: .leading)
        .background(Palette.reviewBand)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editing \(DiffEditSession.span(of: region))")
    }

    /// Which lines of the file this box is, said in the file's own numbering, because that is the
    /// number in the gutter above it and the number an error message would name.
    private var header: some View {
        HStack(spacing: Metrics.spacingSmall) {
            Image(systemName: "pencil")
                .font(Typo.micro)
                .imageScale(.small)
            Text("Editing \(DiffEditSession.span(of: region))")
                .font(Typo.caption)
        }
        .foregroundStyle(Palette.textSecondary)
    }

    private var buttons: some View {
        HStack(spacing: Metrics.spacing) {
            Spacer(minLength: 0)

            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Metrics.spacingWide)
                .padding(.vertical, Metrics.spacingSmall)
                .background(Palette.hover, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
                .help("Put the lines back as the file has them")

            Button(action: onSave) {
                Text("Save")
                    .font(Typo.captionEmphasis)
                    .foregroundStyle(Palette.selectedEmphasizedText)
                    .padding(.horizontal, Metrics.spacingWide)
                    .padding(.vertical, Metrics.spacingSmall)
                    .background(
                        Palette.controlAccent.opacity(isEdited ? 1 : 0.4),
                        in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isEdited)
            // Command+S, the way Edit mode saves. No Return: Return is a newline in a code
            // editor, and a box that submitted on it could not hold two lines.
            .keyboardShortcut("s", modifiers: .command)
            .help("Write these lines to the file (Command S)")
        }
    }

    private var isRefused: Bool {
        if case .failed = status { true } else { false }
    }

    /// Whether the box holds something the file does not, which is the whole of what Save is
    /// offered on. Asked here rather than passed in, deliberately: the diff view builds this row
    /// inside its own `body`, so a question it had to answer would have made every keystroke in
    /// this box invalidate every row of the diff behind it.
    private var isEdited: Bool { region.isEdited(text) }

    /// Counted rather than measured: the editor does not wrap, so one line of text is one line on
    /// screen. It follows what is typed, so a box grows as lines are added to it.
    private var height: CGFloat {
        let lines = max(1, text.components(separatedBy: "\n").count)
        let shown = min(max(lines, Self.minimumLines), Self.maximumLines)
        return CGFloat(shown) * CodeMetrics.rowHeight + Self.verticalPadding
    }
}
