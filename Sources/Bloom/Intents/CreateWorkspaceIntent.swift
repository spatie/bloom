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

        guard await RunningApp.waitUntilReady() else { throw IntentFailure.appNeverAppeared }

        // Straight into the same code the create window runs, and it answers with the workspace or
        // with what went wrong.
        //
        // It used to build a `bloom://` URL, hand it to the window, and then read the database
        // every 400ms for up to sixty seconds looking for a row it had not seen when it started,
        // because a URL is one way and there was nothing to return. Two Shortcuts creating a
        // workspace in one project at the same second could each claim the other's row. A failure
        // was an alert on somebody's screen that the Shortcut never heard about, and the link
        // carried nothing but a prompt and a path, so everything the sheet can choose was silently
        // the default.
        let created = try await RunningApp.startWorkspace(in: repo, prompt: prompt)

        let entity = WorkspaceEntity(
            workspace: created,
            project: repo.name,
            isAgentRunning: await WorkspaceLookup.isAgentRunning(workspaceID: created.id, store: store),
            isAwaitingPermission: await WorkspaceLookup.isAwaitingPermission(workspaceID: created.id, store: store),
            pullRequest: nil
        )
        return .result(value: entity, dialog: "Started \(created.name) in \(repo.name).")
    }
}
