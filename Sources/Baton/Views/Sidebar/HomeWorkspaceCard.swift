import SwiftUI
import BatonCore

/// One workspace on Home: what it is called, what branch it is on, how much it changed and when
/// it last did anything.
///
/// A real `Button` rather than an `onTapGesture`, so it is focusable, keyboard operable and
/// announced as a button. The card used to be a plain stack with a tap gesture attached, which
/// meant VoiceOver read it as four unrelated pieces of text and Full Keyboard Access skipped it.
struct HomeWorkspaceCard: View {
    var workspace: Workspace
    var isHovered: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(workspace.name)
                        .font(Typo.bodyEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    if workspace.unread {
                        Circle()
                            .fill(Palette.accent)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("Unread")
                    }
                }

                HStack(spacing: 6) {
                    Chip(
                        text: workspace.branch,
                        systemImage: "arrow.triangle.branch",
                        monospaced: true
                    )
                    Spacer(minLength: 4)
                    if workspace.hasDiff {
                        DiffStatLabel(
                            additions: workspace.additions,
                            deletions: workspace.deletions
                        )
                    }
                }

                Text(
                    workspace.lastActivityAt,
                    format: .relative(presentation: .numeric, unitsStyle: .abbreviated)
                )
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            }
            .padding(10)
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
        .accessibilityInputLabels([workspace.name])
    }
}
