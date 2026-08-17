import SwiftUI
import BatonCore

/// The centre pane when nothing is selected.
///
/// Home answers one question: what is going on across every project right now. It is grouped by
/// project rather than sorted purely by time, because a developer thinks in projects first and
/// the grouping is what makes a screen of twenty workspaces readable.
struct HomeView: View {
    @Environment(AppModel.self) private var app

    @State private var hovered: String?

    /// Cards refresh together, so sharing one formatter avoids repeated ICU setup per card.
    @MainActor private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 10)]

    var body: some View {
        Group {
            if app.repos.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.windowBackground)
    }

    /// Handed to `RootView`, which owns the only create sheet in the app.
    private func requestWorkspace(in repo: Repo?) {
        NotificationCenter.default.post(name: .batonNewWorkspace, object: repo)
    }

    // MARK: - Populated

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                welcome

                ForEach(app.repos) { repo in
                    let workspaces = recent(in: repo)
                    if !workspaces.isEmpty {
                        section(repo, workspaces)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var welcome: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(summary)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer(minLength: 12)

            Button {
                requestWorkspace(in: nil)
            } label: {
                Label("New workspace", systemImage: "plus")
                    .font(Typo.bodyEmphasis)
                    .padding(.horizontal, 4)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private var greeting: String {
        let name = NSFullUserName().components(separatedBy: .whitespaces).first ?? ""
        return name.isEmpty ? "Welcome back" : "Welcome back, \(name)"
    }

    private var summary: String {
        let active = app.workspaces.count
        let unread = app.workspaces.count(where: \.unread)
        if active == 0 { return "No workspaces yet. Start one and an agent gets to work." }
        let workspaces = active == 1 ? "1 workspace" : "\(active) workspaces"
        if unread == 0 { return "\(workspaces) across \(app.repos.count) projects." }
        return "\(workspaces), \(unread) waiting to be read."
    }

    private func recent(in repo: Repo) -> [Workspace] {
        app.workspaces(in: repo)
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(9)
            .map { $0 }
    }

    private func section(_ repo: Repo, _ workspaces: [Workspace]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hexString: repo.accent))
                    .frame(width: 10, height: 10)
                Text(repo.name)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                Text(repo.defaultBranch)
                    .font(Typo.codeTiny)
                    .foregroundStyle(Palette.textTertiary)

                Spacer(minLength: 8)

                Button {
                    requestWorkspace(in: repo)
                } label: {
                    Label("New", systemImage: "plus")
                        .font(Typo.label)
                }
                .buttonStyle(.borderless)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(workspaces) { workspace in
                    card(workspace)
                }
            }
        }
    }

    private func card(_ workspace: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(workspace.name)
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if workspace.unread {
                    Circle().fill(Palette.accent).frame(width: 6, height: 6)
                }
            }

            HStack(spacing: 6) {
                Chip(text: workspace.branch, systemImage: "arrow.triangle.branch", monospaced: true)
                Spacer(minLength: 4)
                if workspace.hasDiff {
                    DiffStatLabel(additions: workspace.additions, deletions: workspace.deletions)
                }
            }

            Text(relative(workspace.lastActivityAt))
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .stroke(hovered == workspace.id ? Palette.borderStrong : Palette.border, lineWidth: Metrics.hairline)
        }
        .contentShape(Rectangle())
        .onHoverChange { inside in
            hovered = inside ? workspace.id : (hovered == workspace.id ? nil : hovered)
        }
        .onTapGesture { app.selection = .workspace(workspace.id) }
    }

    private func relative(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.textTertiary)

            VStack(spacing: 5) {
                Text("Add your first project")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Point Baton at a git repository. Every workspace you start gets its own worktree and its own agent, so they never step on each other.")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button {
                guard let path = ProjectFolderPicker.choose() else { return }
                Task { await app.addRepository(at: path) }
            } label: {
                Label("Choose a folder", systemImage: "folder")
                    .padding(.horizontal, 4)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}
