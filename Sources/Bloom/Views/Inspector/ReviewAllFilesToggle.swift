import SwiftUI

/// Shares the review pane's mode, with an explicit on state and a way back to one file.
struct ReviewAllFilesToggle: View {
    let model: WorkspaceModel

    private var isOn: Bool {
        CenterTabStore.shared.review(for: model.workspace.id)?.showsAllFiles == true
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { FileReview.setShowsAllFiles($0, in: model) }
        )) {
            Image(systemName: "doc.text")
                .foregroundStyle(isOn ? Palette.textPrimary : Palette.textSecondary)
                .frame(width: Metrics.controlHeight + 4, height: Metrics.controlHeight)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                            .fill(Palette.selected)
                    }
                }
                .frame(width: Metrics.controlHeight + 8, height: InspectorLayout.barHeight)
                .contentShape(Rectangle())
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(isOn ? "Show only the selected file" : "Review all changed files together")
        .accessibilityLabel("Review all files")
        .accessibilityIdentifier("review-all-files-toggle")
    }
}
