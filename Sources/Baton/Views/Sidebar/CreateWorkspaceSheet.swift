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
        .frame(width: 560)
        .background(Palette.surface)
        .task { await load() }
        .onChange(of: repoID) { _, _ in
            Task { await load() }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.rectangle.on.folder")
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.accent)
            Text("New workspace")
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 0)
            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .accessibilityLabel("Loading branches")
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: 38)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
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

            VStack(alignment: .leading, spacing: 5) {
                Text("What should the agent do?")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)

                // A vertical `TextField` rather than a `TextEditor`: it takes a placeholder, it
                // grows with the user's text size instead of clipping inside a pinned 150pt box,
                // and it is still a multi-line field.
                TextField(
                    "Fix the flaky upload test, and say why it was flaky",
                    text: $prompt,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .lineLimit(6...12)
                    .padding(6)
                    .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.corner)
                            .stroke(promptFocused ? Palette.accent.opacity(0.6) : Palette.border, lineWidth: Metrics.hairline)
                    }
                    .focused($promptFocused)
            }

            HStack(spacing: 6) {
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
        VStack(spacing: 8) {
            Text("No projects yet")
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
            Text("Add a git repository before starting a workspace.")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            Button("Add a Folder", action: addProject)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create", action: create)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: 46)
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
