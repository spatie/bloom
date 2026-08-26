import SwiftUI
import BloomCore

/// One workspace whose transcript matched, with the best few lines underneath it.
///
/// The workspace leads because the question is "which workspace was it". The lines underneath are
/// what makes the answer checkable without opening anything: a row that only said "this workspace
/// mentions it" would have to be trusted, and there are usually four of them.
///
/// Each line is its own button. Clicking the workspace opens it where it left off; clicking a line
/// opens it at that line, which is the difference between the feature being useful and being a
/// curiosity.
struct TranscriptResultRow: View {
    var result: TranscriptWorkspaceMatches
    var workspace: Workspace?
    var repo: Repo?
    var isArchived: Bool
    var openWorkspace: () -> Void
    var openMatch: (TranscriptMatch) -> Void

    @State private var hoveredMatch: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            Button(action: openWorkspace) {
                // Top, not centred. The icon sits beside a two-line block (the name, then the
                // project and the match count), and centred it floats between the two lines
                // pointing at neither. Against the first line it reads as the mark on the name,
                // which is what it is.
                HStack(alignment: .top, spacing: Metrics.spacingWide) {
                    RepoIcon(repo: repo)

                    VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                        Text(workspace?.name ?? "Unknown workspace")
                            .font(Typo.bodyEmphasis)
                            .lineLimit(1)

                        HStack(spacing: Metrics.spacingSmall) {
                            if isArchived {
                                Label("Archived", systemImage: "archivebox")
                                    .labelStyle(.titleAndIcon)
                                    .foregroundStyle(Palette.textTertiary)

                                Text(verbatim: "·")
                                    .accessibilityHidden(true)
                            }

                            Text(repo?.name ?? "Unknown project")
                                .lineLimit(1)

                            Text(verbatim: "·")
                                .accessibilityHidden(true)

                            Text(matchCount)
                        }
                        .font(Typo.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: Metrics.spacingWide)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(result.matches) { match in
                Button { openMatch(match) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
                        // The label stays a rung below the snippet. It says which kind of row
                        // matched, which is context for the line beside it rather than the thing
                        // being read, and two equal sizes made the pair read as one grey block.
                        Text(TranscriptSearch.label(for: match.kind))
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                            .frame(width: Self.labelWidth, alignment: .trailing)

                        // A rung up from caption. This is the only text on the screen anybody is
                        // actually reading, since it is the matched line itself, and it was set
                        // smaller than the workspace name above it and the same size as the label
                        // to its left.
                        Text(snippet(match.snippet))
                            .font(Typo.label)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, Metrics.spacingSmall)
                    .padding(.horizontal, Metrics.spacingSmall)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                        .fill(hoveredMatch == match.id ? Palette.hover : .clear)
                )
                .onHoverChange { inside in
                    hoveredMatch = inside ? match.id : (hoveredMatch == match.id ? nil : hoveredMatch)
                }
                .accessibilityHint("Opens the workspace at this point in the transcript.")
            }
            .padding(.leading, Self.snippetInset)
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.spacing)
        .rowBackground(isSelected: false, isHovered: false)
    }

    /// The kind sits in a column of its own so the snippets all start at the same x. Ragged left
    /// edges made four one line results read as four unrelated things.
    private static let labelWidth: CGFloat = 62
    /// Lines up the snippet block under the workspace name rather than under its icon.
    private static let snippetInset: CGFloat = 30

    private var matchCount: String {
        result.total == 1 ? "1 match" : "\(result.total) matches"
    }

    /// One `AttributedString` rather than concatenated `Text`, which is the API that would read
    /// better and is deprecated on macOS 26.
    ///
    /// The matched run is given weight and the primary text colour rather than a highlight fill.
    /// A yellow plate behind two words in a caption sized line, four lines to a result and four
    /// results to a screen, was the loudest thing in the window by some way.
    private func snippet(_ snippet: TranscriptSnippet) -> AttributedString {
        var built = AttributedString()
        for segment in snippet.segments {
            var run = AttributedString(segment.text)
            if segment.isMatch {
                run.inlinePresentationIntent = .stronglyEmphasized
                run.foregroundColor = Palette.textPrimary
            }
            built.append(run)
        }
        return built
    }
}
