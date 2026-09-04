import SwiftUI
import BloomCore

/// One workspace in the panel: its name with the matched characters lit, its project, and one
/// short fact about where it has got to.
///
/// **The name leads and everything else is one quiet line under it**, which is the shape the
/// sidebar's hover card and Home's rows already have. A panel row is read in the half second
/// between typing and pressing Return, so there is room for exactly one line of context and the
/// choice of what goes in it is the whole design of the row: what is waiting on you at rest, and
/// how long ago it happened in a search.
struct SearchPanelWorkspaceRow: View {
    var hit: SearchPanelWorkspaceHit
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @Environment(\.controlActiveState) private var activeState
    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Metrics.spacingWide) {
                RepoIcon(repo: hit.repo)

                VStack(alignment: .leading, spacing: SearchPanelRowMetrics.lineGap) {
                    name
                        .font(Typo.bodyEmphasis)
                        .lineLimit(1)
                    detail
                        .font(Typo.caption)
                        .foregroundStyle(quiet)
                        .lineLimit(1)
                }

                Spacer(minLength: Metrics.spacingWide)
            }
            .searchPanelRowPadding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        // Inset from the card's edges rather than run to them. See `SearchPanelRowPlate`.
        .searchPanelRowPlate(isSelected: isSelected, isHovered: isHovered)
        .onHoverChange { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
    }

    private var name: Text {
        MatchedRuns.text(hit.workspace.name, highlights: hit.highlights, loud: loud, quiet: quiet)
    }

    /// The project, then the one fact worth a row's second line.
    ///
    /// In the resting list that is why the workspace is waiting; in a search it is what matched
    /// when the name did not, because a row matched on its branch would otherwise look unrelated
    /// to what was typed. The age is last in both, because it is the fact people scan for and the
    /// trailing edge is where the eye ends up.
    private var detail: Text {
        var parts: [String] = [hit.repo?.name ?? "Unknown project"]
        if hit.isArchived { parts.append("archived") }
        if let waiting = hit.waiting { parts.append(waiting.label) }
        if let match = hit.match { parts.append(match) }
        parts.append(
            hit.workspace.lastActivityAt.formatted(
                .relative(presentation: .numeric, unitsStyle: .narrow)
            )
        )
        return Text(parts.joined(separator: " \u{00B7} "))
    }

    private var accessibilityLabel: String {
        var parts = [hit.workspace.name]
        if let repo = hit.repo { parts.append("in \(repo.name)") }
        if hit.isArchived { parts.append("archived") }
        if let waiting = hit.waiting { parts.append(waiting.label) }
        if let match = hit.match { parts.append("matched \(match)") }
        return parts.joined(separator: ", ")
    }

    private var loud: Color {
        isEmphasized ? Palette.selectedEmphasizedText : Palette.textPrimary
    }

    private var quiet: Color {
        isEmphasized ? Palette.selectedEmphasizedText.opacity(0.76) : Palette.textSecondary
    }

    /// See `FileMentionRow`: the labels set their own colour, so they have to know when the row
    /// underneath them has gone accent coloured or they stay unreadable on it.
    private var isEmphasized: Bool {
        isSelected && activeState != .inactive
    }
}
