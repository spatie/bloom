import AppIntents
import Foundation
import BloomCore

/// The one people will actually automate: hand Bloom a project and a sentence, get a workspace.
struct CreateWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Workspace"

    static let description = IntentDescription(
        """
        Cuts a git worktree in a Bloom project, opens it, and starts an agent on the prompt. \
        Returns the workspace once Bloom has created it.
        """,
        categoryName: "Workspaces",
        resultValueName: "Workspace"
    )

    /// Creating a workspace starts a `claude` process that Bloom has to own for the whole of its
    /// life. Running this against a background launch would leave the agent parented to an app
    /// that has nothing on screen, so the app comes forward and does the work itself.
    static let openAppWhenRun = true

    @Parameter(title: "Project", description: "The Bloom project to cut the worktree from.")
    var project: ProjectEntity

    @Parameter(
        title: "Prompt",
        description: "What the agent should do. Bloom names the workspace and its branch from this.",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$prompt) in \(\.$project)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WorkspaceEntity> {
        let store = try await IntentDatabase.store()
        guard let repo = try await store.repo(id: project.id) else {
            throw IntentFailure.unknownProject
        }

        // Taken before the request rather than compared by timestamp afterwards: two Shortcuts
        // creating a workspace in the same project at the same second would otherwise each claim
        // the other's.
        let before = Set(try await store.workspaces(repoID: repo.id, includeArchived: true).map(\.id))

        guard await RunningApp.waitUntilReady() else { throw IntentFailure.appNeverAppeared }
        await RunningApp.open(link(repo: repo))

        guard let created = try await waitForWorkspace(in: repo, excluding: before, store: store) else {
            throw IntentFailure.workspaceNeverArrived(prompt)
        }

        let entity = WorkspaceEntity(
            workspace: created,
            project: repo.name,
            isAgentRunning: await WorkspaceLookup.isAgentRunning(workspaceID: created.id, store: store),
            isAwaitingPermission: await WorkspaceLookup.isAwaitingPermission(workspaceID: created.id, store: store),
            pullRequest: nil
        )
        return .result(value: entity, dialog: "Started \(created.name) in \(repo.name).")
    }

    /// `bloom://` is the link Bloom already accepts from scripts and from Conductor, so an intent
    /// creating a workspace goes down the same tested path as everything else that creates one
    /// from outside. Everything is escaped down to the alphanumerics because the parser on the
    /// other side splits on `&` and `=` and treats `+` as a space.
    private func link(repo: Repo) -> URL {
        let escape = { (value: String) in
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
        }
        return URL(string: "bloom://?prompt=\(escape(prompt))&path=\(escape(repo.path))")!
    }

    /// Polls, because the link is one way. The worktree is written to disk before the setup script
    /// runs, so the row appears in seconds even when the workspace is not usable yet; the wait is
    /// generous only to cover a repository large enough for `git worktree add` to take a while.
    private func waitForWorkspace(
        in repo: Repo,
        excluding before: Set<String>,
        store: Store
    ) async throws -> Workspace? {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            let now = try await store.workspaces(repoID: repo.id, includeArchived: true)
            if let created = now.first(where: { !before.contains($0.id) }) { return created }
        }
        return nil
    }
}
