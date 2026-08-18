import SwiftUI
import BatonCore

/// What the agent touched, grouped by directory.
///
/// The grouping is what makes a fifty file change readable in a 380pt column: the directory is
/// said once, dimmed, and every row under it is just a filename and its numbers.
struct ChangedFileList: View {
    let model: WorkspaceModel

    @State private var hoveredPath: String?
    @State private var pendingRevert: ChangedFile?
    /// Derived from `model.changedFiles`, rebuilt only when that list changes. See
    /// `ChangedFileGroup`.
    @State private var groups: [ChangedFileGroup] = []

    var body: some View {
        Group {
            if model.changedFiles.isEmpty {
                empty
            } else {
                list
            }
        }
        .onChange(of: model.changedFiles, initial: true) { _, files in
            groups = ChangedFileGroup.build(from: files)
        }
        // Attached to the list the rows live in, so the dialog animates out of the file it is
        // about rather than out of the window.
        .confirmationDialog(
            "Revert \(pendingRevert?.filename ?? "this file")?",
            isPresented: $pendingRevert.isPresent(),
            presenting: pendingRevert
        ) { file in
            Button("Revert", role: .destructive) { revert(file) }
            Button("Cancel", role: .cancel) {}
        } message: { file in
            Text(file.change == .untracked
                 ? "\(file.path) is untracked, so reverting deletes it. This cannot be undone."
                 : "Discards every change to \(file.path). This cannot be undone.")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            row(file)
                        }
                    } header: {
                        header(group.directory)
                    }
                }
            }
            .padding(.bottom, Metrics.spacingSmall)
        }
    }

    /// "No changes" and "git could not tell us" look identical unless they are said differently,
    /// and the second one quietly convinces the user their agent did nothing.
    @ViewBuilder
    private var empty: some View {
        if model.isLoadingChanges {
            LoadingView("Reading the worktree")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let problem = model.changesError {
            EmptyStateView(
                glyph: "exclamationmark.triangle",
                title: "Could not read the changes",
                message: problem,
                actionTitle: "Try again",
                action: refresh
            )
        } else {
            EmptyStateView(
                glyph: "checkmark.circle",
                title: "No changes yet",
                message: "Nothing in this worktree differs from \(model.workspace.baseBranch)."
            )
        }
    }

    private func header(_ directory: String) -> some View {
        HStack(spacing: Metrics.spacingSmall) {
            Image(systemName: "folder")
                .font(Typo.micro)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(directory.isEmpty ? "Repository root" : directory)
                .font(Typo.micro)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, InspectorLayout.inset)
        .padding(.vertical, Metrics.spacingSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken)
    }

    private func row(_ file: ChangedFile) -> some View {
        let isSelected = model.selectedFilePath == file.path

        return ChangedFileRow(
            file: file,
            isSelected: isSelected,
            fullPath: fullPath(of: file),
            onSelect: { model.selectedFilePath = isSelected ? nil : file.path },
            onRevert: { pendingRevert = file }
        )
        // The fill is applied here rather than inside the row so that the row's own body can read
        // the selection out of the environment and invert its status letter accordingly.
        .rowBackground(isSelected: isSelected, isHovered: hoveredPath == file.path)
        .padding(.horizontal, Metrics.spacingSmall)
        .onHoverChange { hovering in
            hoveredPath = hovering ? file.path : (hoveredPath == file.path ? nil : hoveredPath)
        }
    }

    // MARK: - Actions

    private func fullPath(of file: ChangedFile) -> String {
        (model.workspace.path as NSString).appendingPathComponent(file.path)
    }

    private func refresh() {
        Task { await model.refreshChanges() }
    }

    /// Untracked files have no committed version to restore, so the only honest revert is a
    /// delete. Both paths go through git so the working tree and the index stay in step.
    private func revert(_ file: ChangedFile) {
        let worktree = model.workspace.path
        let arguments = file.change == .untracked
            ? ["clean", "-f", "--", file.path]
            : ["checkout", "--", file.path]

        Task {
            _ = try? await Shell.run("git", arguments, cwd: worktree, timeout: .seconds(20))
            await model.refreshChanges()
        }
    }
}
