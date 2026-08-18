import SwiftUI
import BatonCore

/// One workspace on Home: what it amounts to, what it is called, what branch it is on, how much it
/// changed and when it last did anything.
///
/// The mark comes first, and it is `WorkspaceStatusGlyph`, the same drawing the sidebar column and
/// the legend use. Home without it was a grid of names and timestamps, which cannot answer the only
/// question a screen full of parallel agents raises: which of these fell over, which is still
/// working, and which is finished. A second mark invented here would also be a second thing to keep
/// in step with the legend, and the two copies this app already had of that drawing had drifted.
///
/// A real `Button` rather than an `onTapGesture`, so it is focusable, keyboard operable and
/// announced as a button. The card used to be a plain stack with a tap gesture attached, which
/// meant VoiceOver read it as four unrelated pieces of text and Full Keyboard Access skipped it.
struct HomeWorkspaceCard: View {
    var entry: HomeWorkspace
    var isHovered: Bool
    var action: () -> Void

    private var workspace: Workspace { entry.workspace }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                header
                status
                footer
            }
            .padding(Metrics.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.corner))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.corner)
                    .stroke(
                        isHovered ? Palette.borderStrong : Palette.border,
                        lineWidth: Metrics.hairline
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The mark, the state and the diff are three separate scraps of text once SwiftUI has
        // merged the card, and read out in that order they say nothing. One sentence instead.
        .accessibilityLabel(accessibilityLabel)
        .accessibilityInputLabels([workspace.name])
        .help(entry.summary)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
            // Aligned to the first baseline rather than centred, so the mark sits on the name's
            // line whether the name wraps to one row or two.
            WorkspaceStatusGlyph(status: entry.status)
                .accessibilityHidden(true)

            Text(workspace.name)
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: Metrics.spacingSmall)

            if workspace.pinned {
                Image(systemName: "pin.fill")
                    .font(Typo.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    /// What the state is, when it last moved, and how much has changed, on one line. The diff stat
    /// sits here rather than beside the branch because a branch name is the one thing on the card
    /// that is allowed to take the whole width before it truncates.
    private var status: some View {
        HStack(spacing: Metrics.spacing) {
            Text(entry.status.label)
                .foregroundStyle(WorkspaceStatusGlyph.tint(for: entry.status))
                .lineLimit(1)

            Text(verbatim: "·")
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            Text(
                workspace.lastActivityAt,
                format: .relative(presentation: .numeric, unitsStyle: .abbreviated)
            )
            .foregroundStyle(Palette.textTertiary)
            .lineLimit(1)

            Spacer(minLength: Metrics.spacingSmall)

            if workspace.hasDiff {
                DiffStatLabel(additions: workspace.additions, deletions: workspace.deletions)
            }
        }
        .font(Typo.caption)
    }

    /// The branch, and the project it belongs to wherever that is not already written directly
    /// above the card. Inside a project's own block the swatch would repeat the block's heading on
    /// every card in it.
    private var footer: some View {
        HStack(spacing: Metrics.spacing) {
            Chip(text: workspace.branch, systemImage: "arrow.triangle.branch", monospaced: true)

            if let repo = entry.repo {
                Spacer(minLength: Metrics.spacingSmall)
                HStack(spacing: Metrics.spacingSmall) {
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                        .fill(Color(hexString: repo.accent))
                        .frame(width: Metrics.swatch, height: Metrics.swatch)
                    Text(repo.name)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                .accessibilityHidden(true)
            }
        }
    }

    private var accessibilityLabel: String {
        var text = workspace.name
        if let repo = entry.repo { text += ", in \(repo.name)" }
        text += ", \(entry.summary)"
        if workspace.hasDiff {
            text += ", \(workspace.additions) added, \(workspace.deletions) removed"
        }
        return text
    }
}
