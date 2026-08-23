import SwiftUI
import BloomCore

/// What the Changes list is measuring from, when it is measuring from anything other than the
/// whole of this workspace's work.
///
/// A band under the tab row rather than a chip inside it, and the reason is width. The strip is
/// one row at a pane whose default is 380 points and whose minimum is 280, and it already holds a
/// segmented control that falls back to a pop-up button the moment its segments do not fit: a
/// fourth control in that row, wide enough to name a scope, is how the tab row loses its tabs. A
/// band is the full width of the column, costs nothing at all in the default state because it is
/// not there, and has room to say what a filter chip can only abbreviate.
///
/// It is drawn under the tabs rather than over them because it is a fact about the list beneath
/// it. `InspectorNotice` sits above the tab row for the opposite reason: it is the answer to a
/// button in the strip above.
/// Nothing is read off a model here on purpose. Every one of its four inputs is a decision made
/// in the core and tested there, which is what lets this page be photographed in each of its
/// states without a database, a worktree or a window.
struct DiffScopeBand: View {
    let scope: DiffScope
    let fileCount: Int
    /// What narrowing did to the review comments, when it did anything. See `DiffScope.strandedNote`.
    var note: String?
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack(spacing: InspectorLayout.gap) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)

                Text(scope.badge)
                    .font(Typo.captionEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // The count is in the tab's own title too. It is here as well because this band is
                // what explains the number up there: seven files under "Changes (7)" is only
                // reassuring once something on screen says what the seven were counted from.
                Text(files)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(action: onClear) {
                    Label("Show all changes", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .inspectorBarControl()
                .help("Show all changes")
            }
            .frame(minHeight: InspectorLayout.barHeight - Metrics.spacingSmall * 2)

            // Only when narrowing has actually taken a comment off screen. See
            // `DiffScope.strandedNote`: nothing here is at risk, and the sentence says so, because
            // a comment the reader cannot find reads as a comment that has been thrown away.
            if let note {
                Text(note)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, InspectorLayout.inset)
        .padding(.vertical, Metrics.spacingSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.accent.opacity(InspectorLayout.tintOpacity))
    }

    /// How many files this scope came back with, said in words rather than left as a bare number
    /// beside another bare number.
    private var files: String {
        "\(fileCount) file\(fileCount == 1 ? "" : "s")"
    }
}
