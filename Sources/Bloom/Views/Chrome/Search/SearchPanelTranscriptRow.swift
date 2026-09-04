import SwiftUI
import BloomCore

/// One workspace whose transcript matched, with the best line under it.
///
/// **Drawn differently from a name match, because it is a different fact.** A name match is a
/// subsequence, so the characters that hit are bold and the rest step back. A transcript match is a
/// phrase in a sentence, so it gets the sentence, with the matched words carried at weight and at
/// full colour. That is what the FTS5 snippet already returns, marked, and `TranscriptSearch`
/// already reads it back into segments.
///
/// One row per workspace rather than per message, which is `TranscriptSearch.group`'s decision: a
/// workspace where the agent said the word forty times would otherwise take the whole panel and
/// bury the three others that are the actual answer. Return opens the best of them at its own line.
struct SearchPanelTranscriptRow: View {
    var hit: SearchPanelTranscriptHit
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @Environment(\.controlActiveState) private var activeState
    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(alignment: .top, spacing: Metrics.spacingWide) {
                RepoIcon(repo: hit.repo)

                VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                    HStack(spacing: Metrics.spacingSmall) {
                        Text(hit.workspace?.name ?? "Unknown workspace")
                            .font(Typo.bodyEmphasis)
                            .foregroundStyle(loud)
                            .lineLimit(1)

                        Text(detail)
                            .font(Typo.caption)
                            .foregroundStyle(quiet)
                            .lineLimit(1)
                    }

                    if let snippet = hit.result.best?.snippet, !snippet.isEmpty {
                        Text(marked(snippet))
                            .font(Typo.caption)
                            .foregroundStyle(quiet)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: Metrics.spacingWide)
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, Metrics.spacingSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the workspace at this point in the transcript.")
        .rowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: true)
        .onHoverChange { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
    }

    private var detail: String {
        var parts = [hit.repo?.name ?? "Unknown project"]
        if hit.isArchived { parts.append("archived") }
        parts.append(hit.result.total == 1 ? "1 match" : "\(hit.result.total) matches")
        return parts.joined(separator: " \u{00B7} ")
    }

    private var accessibilityLabel: String {
        "\(hit.workspace?.name ?? "Unknown workspace"), \(detail)"
    }

    /// One `AttributedString` rather than concatenated `Text`, which is the API that would read
    /// better and is deprecated on macOS 26. The matched run gets weight and the loud colour
    /// rather than a highlight plate: a wash behind two words in a caption sized line, four lines
    /// to a panel, was the loudest thing on the card by some way when Home tried it.
    private func marked(_ snippet: TranscriptSnippet) -> AttributedString {
        var built = AttributedString()
        for segment in snippet.segments {
            var run = AttributedString(segment.text)
            if segment.isMatch {
                run.inlinePresentationIntent = .stronglyEmphasized
                run.foregroundColor = loud
            }
            built.append(run)
        }
        return built
    }

    private var loud: Color {
        isEmphasized ? Palette.selectedEmphasizedText : Palette.textPrimary
    }

    private var quiet: Color {
        isEmphasized ? Palette.selectedEmphasizedText.opacity(0.76) : Palette.textSecondary
    }

    private var isEmphasized: Bool {
        isSelected && activeState != .inactive
    }
}
