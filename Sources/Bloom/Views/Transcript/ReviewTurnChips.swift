import SwiftUI
import BloomCore

/// The chips a sent review turn wears in the transcript: the file and the start of the comment,
/// one per comment, in place of the page of scaffolding the agent was actually handed.
///
/// The reader wrote these comments a moment ago on the diff, so the useful record is which files
/// they touched and what they said, not the prompt template around it. The full text is still in
/// the row's payload; this is only how it is drawn, exactly as attachment paths are drawn as
/// file chips. `ReviewTurn.split` is what decides a message qualifies, and when it declines
/// (a customised template, an older wording) the turn renders as its full text instead.
struct ReviewTurnChips: View {
    var chips: [ReviewTurnRecord.Chip]
    var workspace: Workspace

    @Environment(AppModel.self) private var app

    var body: some View {
        ChipFlow(spacing: Metrics.spacingSmall, lineSpacing: Metrics.spacingSmall) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Button {
                    open(chip)
                } label: {
                    Chip(text: chip.label, systemImage: "text.bubble")
                        .frame(maxWidth: 300, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(chip.body)
                .accessibilityLabel("Review comment on \(chip.fileName) line \(chip.line)")
                .accessibilityValue(chip.body)
            }
        }
    }

    /// The same door every file chip in the transcript uses. The line is not scrolled to: the
    /// file may have changed shape since, and a wrong scroll claims more than a right open.
    private func open(_ chip: ReviewTurnRecord.Chip) {
        guard let model = app.existingModel(for: workspace.id) else { return }
        FileReview.open(path: chip.filePath, in: model)
    }
}
