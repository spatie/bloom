import SwiftUI

/// Shares the review pane's mode, with an explicit on state and a way back to one file.
struct ReviewAllFilesToggle<Model: WorkspaceFileListing>: View {
    let model: Model

    private var isOn: Bool {
        CenterTabStore.shared.review(for: model.workspace.id)?.showsAllFiles == true
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { model.setShowsAllFiles($0) }
        )) {
            HStack(spacing: InspectorLayout.tight) {
                Image(systemName: isOn ? "checkmark" : "doc.text")
                    .frame(width: 12)
                Text("Review all")
            }
            .font(Typo.captionEmphasis)
            .foregroundStyle(isOn ? Palette.selectedEmphasizedText : Palette.textSecondary)
            .padding(.horizontal, InspectorLayout.gap)
            .padding(.vertical, InspectorLayout.tight)
            .background {
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .fill(isOn ? Palette.accent : Palette.surface)
                    .strokeBorder(isOn ? Palette.accent : Palette.border, lineWidth: Metrics.outline)
            }
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
