import SwiftUI
import BloomCore

/// Settings shared by every file, drawn once above the continuous review.
struct AllFilesReviewControls<Model: WorkspaceFileListing>: View {
    let model: Model

    @AppStorage(DiffLayoutSetting.storageKey) private var isSideBySide = false
    @AppStorage(DiffWhitespaceSetting.storageKey) private var ignoresWhitespace = false

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            ViewThatFits(in: .horizontal) {
                Text(model.diffScope.isNarrowed
                     ? model.diffScope.badge
                     : model.viewedSummary ?? Counted.of(model.changedFiles.count, "file"))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }

            ViewThatFits(in: .horizontal) {
                Picker("Diff layout", selection: $isSideBySide) {
                    Text(FileBarControls.unified).tag(false)
                    Text(FileBarControls.sideBySide).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }

            Menu {
                Text(model.diffScope.badge)
                Divider()
                Picker("Diff layout", selection: $isSideBySide) {
                    Text(FileBarControls.unified).tag(false)
                    Text(FileBarControls.sideBySide).tag(true)
                }
                .pickerStyle(.inline)
                Toggle("Ignore whitespace", isOn: $ignoresWhitespace)
            } label: {
                Label("Review display options", systemImage: "slider.horizontal.3")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Review display options")
        }
    }
}
