import SwiftUI
import AppKit
import BatonCore

/// The right hand column: what the agent changed, and what GitHub thinks of it.
///
/// Everything here is a thin arrangement of the pieces below it. The tab row owns two settings
/// that its children need (the diff layout, and review mode) because both are chrome level
/// choices that outlive whichever file happens to be selected.
struct InspectorView: View {
    private let model: WorkspaceModel

    init(model: WorkspaceModel) {
        self.model = model
    }

    @AppStorage(DiffLayoutSetting.storageKey) private var isSideBySide = false
    @State private var isReviewing = false

    var body: some View {
        VStack(spacing: 0) {
            PullRequestBar(model: model)
            Hairline()
            tabs
            Hairline()
            content
        }
        .background(Palette.surface)
    }

    // MARK: - Tabs

    private var tabs: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(InspectorTab.allCases, id: \.self) { tab in
                        tabButton(tab)
                    }
                }
            }
            .scrollIndicators(.never)

            iconButton(
                isReviewing ? "eye.fill" : "eye",
                help: "Review the changes one file at a time",
                isOn: isReviewing
            ) {
                isReviewing.toggle()
                if isReviewing, model.selectedFilePath == nil {
                    model.selectedFilePath = model.changedFiles.first?.path
                }
            }

            iconButton(
                isSideBySide ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                help: isSideBySide ? "Show a unified diff" : "Show the diff side by side",
                isOn: isSideBySide
            ) {
                isSideBySide.toggle()
            }

            Menu {
                Button("Refresh") {
                    Task {
                        await model.refreshChanges()
                        await model.refreshPullRequest()
                    }
                }
                Divider()
                Button("Copy branch name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.workspace.branch, forType: .string)
                }
                Button("Reveal worktree in Finder") { Reveal.inFinder(model.workspace.path) }
                Button("Open worktree in Editor") { Reveal.inEditor(model.workspace.path) }
                if let pullRequest = model.pullRequest {
                    Divider()
                    Button("Open pull request") { GitHubBridge.open(pullRequest.url) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
    }

    private func tabButton(_ tab: InspectorTab) -> some View {
        let isSelected = model.inspectorTab == tab

        return Button {
            model.inspectorTab = tab
        } label: {
            HStack(spacing: 4) {
                Text(tab.rawValue)
                    .font(isSelected ? Typo.labelEmphasis : Typo.label)
                    .lineLimit(1)
                    .fixedSize()
                if tab == .changes, !model.changedFiles.isEmpty {
                    Text("\(model.changedFiles.count)")
                        .font(Typo.micro)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                isSelected ? Palette.selected : .clear,
                in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isOn ? Palette.accent : Palette.textSecondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.inspectorTab {
        case .allFiles:
            FileTreeView(model: model)
        case .changes:
            changes
        case .checks:
            ChecksView(model: model)
        }
    }

    @ViewBuilder
    private var changes: some View {
        if isReviewing, let file = model.selectedFile ?? model.changedFiles.first {
            review(file)
        } else {
            VSplitLayout(
                top: { ChangedFileList(model: model) },
                bottom: {
                    if let file = model.selectedFile {
                        DiffView(model: model, file: file)
                    }
                },
                hasBottom: model.selectedFile != nil
            )
        }
    }

    /// Review mode drops the list and walks the files one at a time, which is how a diff is
    /// actually read once you have decided to read all of it.
    private func review(_ file: ChangedFile) -> some View {
        let index = model.changedFiles.firstIndex { $0.path == file.path } ?? 0
        let total = max(model.changedFiles.count, 1)

        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    step(-1, from: index)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button {
                    step(1, from: index)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(index >= total - 1)

                Text(file.filename)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Text("\(index + 1) of \(total)")
                    .font(Typo.micro)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
                DiffStatLabel(additions: file.additions, deletions: file.deletions, compact: true)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Palette.surfaceSunken)

            Hairline()
            DiffView(model: model, file: file)
        }
    }

    private func step(_ delta: Int, from index: Int) {
        let target = index + delta
        guard model.changedFiles.indices.contains(target) else { return }
        model.selectedFilePath = model.changedFiles[target].path
    }
}
