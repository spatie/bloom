import SwiftUI
import AppKit
import BatonCore

/// What the agent touched, grouped by directory.
///
/// The grouping is what makes a fifty file change readable in a 380pt column: the directory is
/// said once, dimmed, and every row under it is just a filename and its numbers.
struct ChangedFileList: View {
    let model: WorkspaceModel

    @State private var hoveredPath: String?
    @State private var pendingRevert: ChangedFile?

    private var groups: [(directory: String, files: [ChangedFile])] {
        let grouped = Dictionary(grouping: model.changedFiles) { $0.directory }
        return grouped
            .map { (directory: $0.key, files: $0.value.sorted { $0.filename < $1.filename }) }
            .sorted { $0.directory < $1.directory }
    }

    var body: some View {
        Group {
            if model.changedFiles.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.directory) { group in
                            Section {
                                ForEach(group.files) { file in
                                    row(file)
                                }
                            } header: {
                                header(group.directory)
                            }
                        }
                    }
                    .padding(.bottom, InspectorLayout.tight * 2)
                }
            }
        }
        .confirmationDialog(
            "Revert \(pendingRevert?.filename ?? "this file")?",
            isPresented: Binding(
                get: { pendingRevert != nil },
                set: { if !$0 { pendingRevert = nil } }
            ),
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
                action: { Task { await model.refreshChanges() } }
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
        HStack(spacing: InspectorLayout.tight * 2) {
            Image(systemName: "folder")
                .font(Typo.micro)
                .imageScale(.small)
            Text(directory.isEmpty ? "Repository root" : directory)
                .font(Typo.micro)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, InspectorLayout.inset)
        .padding(.vertical, InspectorLayout.tight * 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken)
    }

    private func row(_ file: ChangedFile) -> some View {
        let isSelected = model.selectedFilePath == file.path

        return Button {
            model.selectedFilePath = isSelected ? nil : file.path
        } label: {
            HStack(spacing: InspectorLayout.gap) {
                glyph(file.change)
                Text(file.filename)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: InspectorLayout.tight * 2)
                if file.isBinary {
                    Chip(text: "bin")
                } else {
                    DiffStatLabel(additions: file.additions, deletions: file.deletions, compact: true)
                }
                Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                    .font(Typo.micro)
                    .imageScale(.small)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, InspectorLayout.gap)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowBackground(isSelected: isSelected, isHovered: hoveredPath == file.path)
        .padding(.horizontal, InspectorLayout.tight * 2)
        .onHover { hovering in
            hoveredPath = hovering ? file.path : (hoveredPath == file.path ? nil : hoveredPath)
        }
        .contextMenu { menu(for: file) }
        .help(file.path)
    }

    @ViewBuilder
    private func menu(for file: ChangedFile) -> some View {
        Button("Open in Editor") { Reveal.inEditor(fullPath(of: file)) }
        Button("Reveal in Finder") { Reveal.inFinder(fullPath(of: file)) }
        Button("Copy path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        }
        Divider()
        Button("Revert this file", role: .destructive) { pendingRevert = file }
    }

    /// The status letter git uses, so the list reads the same as `git status` does.
    private func glyph(_ change: ChangedFile.Change) -> some View {
        Text(change.rawValue)
            .font(Typo.codeTiny)
            .foregroundStyle(color(for: change))
            .frame(width: InspectorLayout.glyphWidth, height: InspectorLayout.glyphWidth)
            .background(
                color(for: change).opacity(InspectorLayout.tintOpacity),
                in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
            )
    }

    private func color(for change: ChangedFile.Change) -> Color {
        switch change {
        case .added, .untracked: Palette.positive
        case .deleted: Palette.negative
        case .modified: Palette.warning
        case .renamed, .copied: Palette.accent
        }
    }

    private func fullPath(of file: ChangedFile) -> String {
        (model.workspace.path as NSString).appendingPathComponent(file.path)
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
