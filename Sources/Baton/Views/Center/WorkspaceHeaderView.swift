import SwiftUI
import AppKit
import BatonCore

/// The bar that says where you are.
///
/// A workspace is a branch in a worktree, and the two facts people keep needing are which project
/// it belongs to and which branch they are about to push. Everything else in the header is a
/// door: the overflow menu leads out of Baton, the two toggles decide how much of Baton is left.
struct WorkspaceHeaderView: View {
    @Bindable var model: WorkspaceModel

    @Environment(AppModel.self) private var app

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var didCopyBranch = false

    var body: some View {
        HStack(spacing: 6) {
            breadcrumb
            overflowMenu
            Spacer(minLength: 12)
            panelToggles
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: 38)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Hairline() }
        .alert("Rename workspace", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { commitRename() }
        }
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hexString: model.repo?.accent ?? "4C8DF6"))
                .frame(width: 8, height: 8)

            Text(model.repo?.name ?? "Project")
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)

            Text(didCopyBranch ? "Copied" : model.workspace.branch)
                .font(Typo.code)
                .foregroundStyle(didCopyBranch ? Palette.positive : Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.workspace.branch)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var overflowMenu: some View {
        Menu {
            Button("Open in Editor") { Reveal.inEditor(model.workspace.path) }
            Button("Reveal in Finder") { Reveal.inFinder(model.workspace.path) }
            Button("Copy branch") { copyBranch() }
            Divider()
            Button("Rename\u{2026}") {
                renameText = model.workspace.name
                isRenaming = true
            }
            Button("Archive", role: .destructive) {
                let app = app
                let workspace = model.workspace
                Task { await app.archive(workspace) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Panels

    /// One control, two halves, because the inspector and the bottom panel are the same kind of
    /// decision: how much of the window the transcript gets.
    private var panelToggles: some View {
        HStack(spacing: 0) {
            toggle(
                systemImage: "sidebar.right",
                isOn: model.isInspectorVisible,
                help: "Show the inspector"
            ) {
                model.isInspectorVisible.toggle()
            }

            Hairline(axis: .vertical)
                .frame(height: 16)

            toggle(
                systemImage: "rectangle.bottomthird.inset.filled",
                isOn: model.isBottomPanelVisible,
                help: "Show the terminal panel"
            ) {
                model.isBottomPanelVisible.toggle()
            }
        }
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .stroke(Palette.border, lineWidth: Metrics.hairline)
        }
    }

    private func toggle(
        systemImage: String,
        isOn: Bool,
        help: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? Palette.accent : Palette.textTertiary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isOn ? Palette.selected : .clear)
        .help(help)
    }

    // MARK: - Actions

    private func copyBranch() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.workspace.branch, forType: .string)
        didCopyBranch = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            didCopyBranch = false
        }
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let app = app
        let workspace = model.workspace
        Task { await app.rename(workspace, to: name) }
    }
}
