import SwiftUI
import BatonCore

/// The sheet that starts a workspace.
///
/// Creating a workspace is irreversible enough to be worth a moment of thought (it cuts a branch
/// and a worktree on disk), so the sheet shows the branch name it is about to create before the
/// user commits. That preview mirrors what `WorkspaceManager` does, prefix included, which is the
/// only way the feedback is worth anything.
struct CreateWorkspaceSheet: View {
    /// Which project to start in. The sidebar passes the repo whose `+` was clicked, otherwise
    /// the repo of whatever is selected.
    var initialRepo: Repo?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var repoID: String?
    @State private var prompt = ""
    @State private var baseBranch = ""
    @State private var branches: [String] = []
    @State private var branchPrefix: String?
    @State private var isLoading = false

    @FocusState private var promptFocused: Bool

    /// Wide enough for two branch pickers side by side without the sheet reading as a window.
    private static let width: CGFloat = 560
    private static let headerHeight: CGFloat = 38
    private static let footerHeight: CGFloat = 46

    private var repo: Repo? { app.repos.first { $0.id == repoID } }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool { repo != nil && !trimmedPrompt.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()

            if app.repos.isEmpty {
                noProjects
            } else {
                form
            }

            Hairline()
            buttons
        }
        .frame(width: Self.width)
        .background(Palette.surface)
        .task { await load() }
        .onChange(of: repoID) { _, _ in
            Task { await load() }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: Metrics.spacingWide) {
            Image(systemName: "plus.rectangle.on.folder")
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.accent)
            Text("New workspace")
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 0)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading branches")
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Self.headerHeight)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            HStack(spacing: Metrics.gutter) {
                Picker("Project", selection: $repoID) {
                    ForEach(app.repos) { candidate in
                        Text(candidate.name).tag(Optional(candidate.id))
                    }
                }
                .frame(maxWidth: .infinity)

                Picker("From", selection: $baseBranch) {
                    ForEach(branchOptions, id: \.self) { branch in
                        Text(branch).tag(branch)
                    }
                }
                .frame(maxWidth: .infinity)
                .disabled(branchOptions.isEmpty)
            }
            .font(Typo.body)

            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text("What should the agent do?")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)

                // A vertical `TextField` rather than a `TextEditor`: it takes a placeholder, it
                // grows with the user's text size instead of clipping inside a pinned 150pt box,
                // and it is still a multi-line field.
                //
                // `.roundedBorder` rather than a plain field inside a stroked rectangle we draw
                // ourselves: the bezel and, more importantly, the focus ring are then the system's,
                // so the field shows focus the way every other text field on the Mac does and
                // follows increased contrast and the accent colour without being told.
                TextField(
                    "Fix the flaky upload test, and say why it was flaky",
                    text: $prompt,
                    axis: .vertical
                )
                    .textFieldStyle(.roundedBorder)
                    .font(Typo.body)
                    .lineLimit(6...12)
                    .focused($promptFocused)
            }

            HStack(spacing: Metrics.spacing) {
                Text("Branch")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                Chip(text: branchPreview, systemImage: "arrow.triangle.branch", monospaced: true)
                Spacer(minLength: 0)
                Text("worktree in ~/baton/workspaces")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(Metrics.gutter)
    }

    private var noProjects: some View {
        ContentUnavailableView {
            Label("No projects yet", systemImage: "folder.badge.plus")
        } description: {
            Text("Add a git repository before starting a workspace.")
        } actions: {
            Button("Add a Folder", action: addProject)
                .buttonStyle(.borderedProminent)
        }
    }

    private var buttons: some View {
        HStack(spacing: Metrics.spacingWide) {
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create", action: create)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Self.footerHeight)
    }

    // MARK: - Derived

    private var branchOptions: [String] {
        guard let repo else { return branches }
        if branches.isEmpty { return [repo.defaultBranch] }
        return branches
    }

    /// Mirrors `WorkspaceManager.createWorkspace`, minus the uniquing suffix which depends on
    /// branches that could appear between now and Create.
    private var branchPreview: String {
        guard !trimmedPrompt.isEmpty else { return "named from your prompt" }
        let slug = Git.slug(from: trimmedPrompt)
        guard let prefix = branchPrefix, !prefix.isEmpty else { return slug }
        return "\(prefix)/\(slug)"
    }

    // MARK: - Actions

    private func load() async {
        if repoID == nil {
            repoID = initialRepo?.id
                ?? app.selectedWorkspace.flatMap { app.repo(for: $0) }?.id
                ?? app.repos.first?.id
        }
        guard let repo else { return }

        promptFocused = true
        isLoading = true
        defer { isLoading = false }

        let path = repo.path
        let loaded = await Task.detached(priority: .userInitiated) { () -> ([String], String?) in
            let names = (try? await Git.branches(of: path)) ?? []
            return (names, SettingsLoader.load(repo: path).branchPrefix)
        }.value

        branches = loaded.0
        branchPrefix = loaded.1

        if !branches.contains(baseBranch) {
            baseBranch = branches.contains(repo.defaultBranch)
                ? repo.defaultBranch
                : (branches.first ?? repo.defaultBranch)
        }
    }

    private func addProject() {
        guard let path = ProjectFolderPicker.choose() else { return }
        Task { await app.addRepository(at: path) }
    }

    private func create() {
        guard let repo, canCreate else { return }
        let text = trimmedPrompt
        let base = baseBranch.isEmpty ? repo.defaultBranch : baseBranch
        dismiss()
        Task { await app.createWorkspace(in: repo, prompt: text, baseBranch: base) }
    }
}
