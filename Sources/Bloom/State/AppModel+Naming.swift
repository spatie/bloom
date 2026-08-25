import Foundation
import BloomCore

extension AppModel {
    /// Whether a workspace about to be created should be named by a model.
    ///
    /// The rule itself is `WorkspaceNaming.shouldName`, in the core and unit tested. What is left
    /// here is only reading the two facts about this machine that a pure function cannot know: the
    /// setting, and whether the CLI is installed.
    func shouldNameAutomatically(name: String?, prompt: String, opensWith: WorkspaceStartMode) -> Bool {
        WorkspaceNaming.shouldName(
            userSuppliedName: name,
            prompt: prompt,
            isChatWorkspace: opensWith == .chat,
            isEnabled: WorkspaceNamingPreferences().isEnabled,
            isAgentAvailable: WorkspaceNamer.isAvailable
        )
    }

    /// A codename no workspace in this database is wearing.
    ///
    /// Archived ones count. A placeholder that collides with something archived would look fine
    /// until the user opened Home with archived shown, and the whole point of the scheme is that
    /// two rows never carry the same word.
    func placeholderName() async -> String {
        var taken = Set(workspaces.map(\.name))
        taken.formUnion(await archivedWorkspaces().map(\.name))
        return WorkspaceNaming.placeholder(avoiding: taken)
    }

    /// Asks a model what this workspace should be called, and applies the answer if it may.
    ///
    /// Detached from creation on purpose. Nothing waits for it: the worktree exists, the setup
    /// script is running and the first turn has been sent before this task has done anything at
    /// all. If it never finishes, the workspace keeps its codename until the fallback lands.
    func beginAutomaticNaming(
        workspace: Workspace,
        repo: Repo,
        prompt: String,
        placeholder: String
    ) {
        Task { [weak self] in
            await self?.nameAutomatically(
                workspace: workspace,
                repo: repo,
                prompt: prompt,
                placeholder: placeholder
            )
        }
    }

    private func nameAutomatically(
        workspace: Workspace,
        repo: Repo,
        prompt: String,
        placeholder: String
    ) async {
        guard let manager else { return }

        // Read on the main actor before the long await, because the settings file is the same one
        // `createWorkspace` used and re-reading it after the model answers could pick up an edit
        // made in between.
        let branchPrefix = SettingsLoader.load(repo: repo.path).branchPrefix
        let template = PromptOverrides().template(for: .nameWorkspace)

        let suggested = await WorkspaceNamer().suggest(
            task: prompt,
            project: repo.name,
            template: template,
            branchPrefix: branchPrefix
        )

        // Everything the model could not answer collapses to the same thing: the name this
        // workspace would have had if the feature had never existed. The branch is already that,
        // because it was cut from `Git.slug` and nothing has touched it.
        let suggestion = suggested ?? WorkspaceNameSuggestion(
            name: Git.title(from: prompt),
            branch: ""
        )

        let hasPullRequest = WorkspacePullRequests.shared.pullRequest(for: workspace.id) != nil

        let outcome = try? await manager.applyName(
            suggestion,
            to: workspace.id,
            placeholder: placeholder,
            hasPullRequest: hasPullRequest
        )
        guard let result = outcome, result.didRename else { return }

        // The register is written here rather than left to the row, because more than one view
        // can be drawing this name when it lands and they have to scramble in step. `applyName`
        // has already written the row, so the sidebar is on its way to the new name through the
        // store's change feed; `WorkspaceNameText` reads the register from its body and keys its
        // animation on the reveal's id, so an announcement that arrives after the name still
        // plays. Nothing here depends on which of the two lands first.
        WorkspaceNameReveals.shared.announce(
            workspaceID: result.workspace.id,
            name: result.workspace.name
        )

        if let notice = result.notice {
            self.notice = BloomNotice(message: notice)
        }
    }
}
