import SwiftUI
import BloomCore

/// Every project, from a button at the foot of the pane: the one place that lists all of them
/// whatever shape the pane is in and whatever the filter is doing.
///
/// It exists because of two things the pane deliberately no longer does. A project with no
/// workspaces is not drawn at all, and in the status view no project headers are drawn either, so
/// the header's `+` and its settings gear have nowhere to live. Both are here instead, on a row per
/// project, with the hidden ones included and marked: this is also the only route back to a project
/// somebody hid, other than the filter menu's switch.
///
/// A popover rather than a menu, because a menu cannot carry two controls on one row. Each row is
/// the project, a `+` that starts a workspace in it, and a gear that opens its settings, which is
/// exactly what a project header offers under the pointer.
struct SidebarProjectsPopover: View {
    /// Raised to the sidebar, which posts for the create window, so every entry point behaves the
    /// same way. See `SidebarView.presentCreate`.
    var onCreateWorkspace: (Repo) -> Void
    var onStartProject: () -> Void
    var onDismiss: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    private static let width: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(app.repos) { repo in
                row(repo)
            }

            if app.repos.isEmpty {
                Text("No projects yet")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.vertical, Metrics.spacingSmall)
            }

            Divider()
                .padding(.vertical, Metrics.spacingSmall)

            Button {
                onDismiss()
                onStartProject()
            } label: {
                Label(MenuBarCatalogue[.startProject].title, systemImage: "folder.badge.plus")
                    .font(Typo.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textPrimary)
            .padding(.vertical, Metrics.spacingSmall)
        }
        .padding(Metrics.spacingWide)
        .frame(width: Self.width)
    }

    private func row(_ repo: Repo) -> some View {
        HStack(spacing: Metrics.spacing) {
            RepoIcon(repo: repo, size: Metrics.repoIconSmall)

            Text(repo.name)
                .font(Typo.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                // A hidden project is drawn where it would be, at the size it would be, in less
                // ink: the same restraint the header itself uses when they are shown in the pane.
                .foregroundStyle(Palette.textPrimary)
                .opacity(repo.hidden ? SidebarMetrics.hiddenDim : 1)

            if repo.hidden {
                Text("Hidden")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
            }

            Spacer(minLength: Metrics.spacingSmall)

            Text(count(of: repo).formatted(Figures.count))
                .font(Typo.micro)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            Button {
                onDismiss()
                onCreateWorkspace(repo)
            } label: {
                Image(systemName: "plus")
                    .font(Typo.label)
                    .frame(width: Metrics.headerButton.width, height: Metrics.headerButton.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textSecondary)
            .help("New workspace in \(repo.name)")
            .accessibilityLabel("New workspace in \(repo.name)")

            Button {
                onDismiss()
                openWindow(id: RepoSettingsWindow.id, value: repo.id)
            } label: {
                Image(systemName: "gearshape")
                    .font(Typo.label)
                    .frame(width: Metrics.headerButton.width, height: Metrics.headerButton.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textSecondary)
            .help("Settings for \(repo.name)")
            .accessibilityLabel("Settings for \(repo.name)")
        }
        .padding(.vertical, Metrics.spacingTight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(repo))
    }

    private func count(of repo: Repo) -> Int {
        app.workspaces.count { $0.repoID == repo.id }
    }

    private func accessibilityLabel(_ repo: Repo) -> String {
        let counted = count(of: repo) == 1
            ? "\(repo.name), 1 workspace"
            : "\(repo.name), \(count(of: repo)) workspaces"
        return repo.hidden ? counted + ", hidden" : counted
    }
}
