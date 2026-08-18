import SwiftUI
import BatonCore

/// What the agent asked, and the answers it offered.
///
/// Read only. The question was answered in the CLI, in the turn this row belongs to, so these are
/// the options as they were put rather than something still to choose between.
struct QuestionListView: View {
    var questions: [JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.inset) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: TranscriptLayout.proseLeading) {
                    Text(question["question"]?.stringValue ?? "")
                        .font(Typo.bodyEmphasis)
                        .foregroundStyle(Palette.textPrimary)

                    ForEach(Array((question["options"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, option in
                        HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.inset) {
                            Image(systemName: "circle")
                                .font(Typo.label)
                                .imageScale(.small)
                                .foregroundStyle(Palette.textTertiary)
                                .accessibilityHidden(true)

                            Text(option["label"]?.stringValue ?? "")
                                .font(Typo.label)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
        }
    }
}
