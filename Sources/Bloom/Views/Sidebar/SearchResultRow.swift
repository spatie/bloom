import SwiftUI

/// One search hit: the workspace name, then the project it belongs to and the branch it is on.
///
/// Two lines rather than one. On one line the project name, the workspace name and the branch all
/// competed for the same width, and the project collapsed to a letter and a half while the name
/// was still elided. The name leads because it is what was searched for; everything that places
/// it sits underneath in one quiet line, which is how Spotlight and Mail lay a result out.
///
/// A `Button` rather than a tapped `HStack`, so VoiceOver reads it as one actionable row instead
/// of five loose labels. It used to say that a `Button` is also how a keyboard user reaches it,
/// and that was only true with Full Keyboard Access turned on, which it is not by default. The
/// arrows and Return come from the search field above instead: see `SearchView.handle(key:)`.
struct SearchResultRow: View {
    var hit: AppModel.SearchHit
    /// Whether the arrows and Return are pointed at this row. It was hard-coded false, so nothing
    /// on this screen was ever highlighted and the list had no answer to "which one would Return
    /// open".
    var isSelected: Bool
    var isHovered: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.spacingWide) {
                RepoIcon(repo: hit.repo)

                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    Text(hit.workspace.name)
                        .font(Typo.bodyEmphasis)
                        .lineLimit(1)

                    HStack(spacing: Metrics.spacingSmall) {
                        // First, because it changes what the row will do when it is clicked: an
                        // archived hit opens a reader rather than the workspace.
                        if hit.isArchived {
                            Label("Archived", systemImage: "archivebox")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(Palette.textTertiary)

                            Text(verbatim: "\u{00B7}")
                                .accessibilityHidden(true)
                        }

                        Text(hit.repo?.name ?? "Unknown project")
                            .lineLimit(1)

                        Text(verbatim: "·")
                            .accessibilityHidden(true)

                        Text(hit.workspace.branch)
                            .font(Typo.codeTiny)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: Metrics.spacingWide)

                if hit.workspace.hasDiff {
                    DiffStatLabel(
                        additions: hit.workspace.additions,
                        deletions: hit.workspace.deletions,
                        compact: true
                    )
                }
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, Metrics.spacing)
            // A minimum rather than a fixed height, so a row grows with the user's text size
            // instead of clipping its own contents at larger settings.
            .frame(minHeight: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `isFocused` unconditionally, and it is the honest answer rather than a shortcut. The
        // emphasised fill means "the arrow keys move this", which on this screen is true from the
        // moment it opens: the field takes the keyboard on appear and forwards both arrows and
        // Return down here. The window going background still quietens it, inside `RowBackground`.
        .rowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: true)
        .accessibilityInputLabels([hit.workspace.name])
        .accessibilityHint(hit.isArchived ? "Archived. Opens the transcript." : "")
    }
}
