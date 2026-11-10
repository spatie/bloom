import SwiftUI
import BloomCore

/// A plan the agent proposed, drawn whole and formatted where it was proposed. See `PlanRow` for
/// why this is not a tool row any more.
///
/// **A card rather than prose**, because it is not the agent talking: it is the document the
/// approval under it is about, and the one thing in a planning turn somebody reads twice. The card
/// keeps it apart from the explanation the agent writes beside it.
///
/// **Not cut and not folded.** The plan is what was asked for, and a "Show all" in front of it is
/// the grey row again with a different label. The pane scrolls.
///
/// The approval card under it no longer repeats the plan. It printed the Markdown as plain text,
/// and once answered, in the monospace block meant for a shell command.
struct PlanRowView: View {
    var markdown: String

    @Environment(\.chatMeasures) private var chatMeasures

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.cardInset) {
            header

            MarkdownView(markdown)
                .environment(\.markdownProseMeasure, chatMeasures.prose)
                .font(Typo.body)
                .proseLeading()
                .textSelection(.enabled)
        }
        .padding(TranscriptLayout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .fill(Palette.questionWashSettled)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: Metrics.outline)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, TranscriptLayout.tight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plan")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
            Image(systemName: "list.bullet.rectangle")
                .font(Typo.caption)
                .imageScale(.small)
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)

            Text("Plan")
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: TranscriptLayout.glyphGap)

            CopyButton(text: markdown, title: "Copy the plan")
        }
    }
}
