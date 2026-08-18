import SwiftUI
import BloomCore

/// Review mode: the file list steps aside and the changes are walked one at a time, which is how
/// a diff is actually read once you have decided to read all of it.
struct InspectorReviewPane: View {
    let model: WorkspaceModel
    let file: ChangedFile

    private var index: Int {
        model.changedFiles.firstIndex { $0.path == file.path } ?? 0
    }

    private var total: Int {
        max(model.changedFiles.count, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: InspectorLayout.gap) {
                Button("Previous file", systemImage: "chevron.left") { step(-1) }
                    .labelStyle(.iconOnly)
                    .inspectorBarControl()
                    .disabled(index == 0)
                    .help("Previous file")

                Button("Next file", systemImage: "chevron.right") { step(1) }
                    .labelStyle(.iconOnly)
                    .inspectorBarControl()
                    .disabled(index >= total - 1)
                    .help("Next file")

                // Deliberately not the filename: `FileHeaderBar` is the next row down and says
                // it already, in a heavier weight and with its folder beside it. Saying it twice
                // in two adjacent bars reads as a bug rather than as emphasis.
                Text("Reviewing")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)

                Spacer(minLength: InspectorLayout.tight)

                Text("\(index + 1) of \(total)")
                    .font(Typo.micro)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
                DiffStatLabel(additions: file.additions, deletions: file.deletions, compact: true)
            }
            .padding(.horizontal, InspectorLayout.inset)
            // A bar, not a row: it sits directly above `FileHeaderBar`, and four points shorter
            // than the bar under it read as a rendering mistake rather than as a hierarchy.
            .frame(height: InspectorLayout.barHeight)
            .background(Palette.surfaceSunken)

            Hairline()
            DiffView(model: model, file: file)
        }
    }

    private func step(_ delta: Int) {
        let target = index + delta
        guard model.changedFiles.indices.contains(target) else { return }
        model.selectedFilePath = model.changedFiles[target].path
    }
}
