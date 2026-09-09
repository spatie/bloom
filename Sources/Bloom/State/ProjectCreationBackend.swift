import Foundation
import Observation
import BloomCore

/// The shared creation views select a machine here; they never resolve a remote path on the Mac.
@MainActor
struct ProjectCreationBackend {
    let app: AppModel
    let isRemote: Bool

    func request(_ action: ServerCreationOperation) async throws -> ServerCreationResult {
        if isRemote {
            let server = app.remoteServer
            if !server.isConnected { server.connectionMode = .remote; await server.connect() }
            let result: ServerResult
            if action.isMutation {
                guard let value = await server.perform(.creation(action)) else { throw ServerFailure(server.error ?? "Could not update the remote project.") }
                result = value
            } else { result = try await server.read(.creation(action)) }
            guard case .creation(let value) = result else { throw ServerFailure("Update the server to use shared project creation.") }
            return value
        }
        guard let store = app.store else { throw ServerFailure("The project list is still loading.") }
        return try await ProjectCreationOperations.perform(action, store: store)
    }

    func repositories(query: String, page: Int) async throws -> [GitHubRepositoryListing] {
        guard case .repositories(let values) = try await request(.githubRepositories(query: query, page: page)) else { return [] }
        return values
    }

    func importGitHub(_ name: String) async throws -> Repo {
        guard case .project(let repo) = try await request(.importGitHub(name)) else { throw ServerFailure("The project was not returned.") }
        return try await register(repo)
    }

    func refreshRemote() async throws {
        guard case .catalogue(let catalogue) = try await app.remoteServer.read(.catalogue) else { throw ServerFailure("Could not refresh the server projects.") }
        app.remoteServer.catalogue = catalogue
    }

    func startWorkspace(
        repo: Repo, text: String, mode: WorkspaceStartMode, base: String,
        checkout: WorkspaceCheckout?, controls: ComposerControls, runSetup: Bool, staged: StagedAttachments
    ) async throws {
        var request = ServerWorkspaceRequest(repositoryPath: repo.path, name: text)
        request.prompt = mode.runsAnAgent ? text : nil
        request.mode = mode
        request.baseBranch = base
        request.checkout = checkout
        request.controls = controls
        request.runSetupScript = runSetup
        request.attachments = try staged.attachments.map { attachment in
            ServerInitialAttachment(sourcePath: attachment.path, name: attachment.url(in: staged.directory).lastPathComponent,
                data: try Data(contentsOf: attachment.url(in: staged.directory)))
        }
        let server = app.remoteServer
        guard let result = await server.perform(.create(request)),
            case .creation(.workspaceStarted(let workspace, let session, _, let draft)) = result else {
            throw ServerFailure(server.error ?? "Could not create the workspace.")
        }
        server.prepareCreatedWorkspace(workspace, opensWith: mode)
        if server.catalogue?.workspaces.contains(where: { $0.id == workspace.id }) == false { server.catalogue?.workspaces.append(workspace) }
        if let session, server.catalogue?.sessions.contains(where: { $0.id == session.id }) == false { server.catalogue?.sessions.append(session) }
        try? await refreshRemote()
        server.selectWorkspace(workspace.id)
        app.selection = .remoteWorkspace(workspace.id)
        if let session {
            if let draft { server.saveRemoteDraft(draft, sessionID: session.id) }
            app.selectRemoteSession(session.id)
        }
    }

    func register(_ repo: Repo) async throws -> Repo {
        if isRemote {
            if app.remoteServer.catalogue?.repositories.contains(where: { $0.id == repo.id }) == false { app.remoteServer.catalogue?.repositories.append(repo) }
            try? await refreshRemote()
            return repo
        }
        guard let registered = await app.addStartedProject(at: repo.path) else { throw ServerFailure("Could not add the project to the sidebar.") }
        return registered
    }
}

private extension ServerCreationOperation {
    var isMutation: Bool {
        switch self {
        case .importGitHub, .startProject: true
        default: false
        }
    }
}

@MainActor
@Observable
final class CreationComposerSource {
    let models = ComposerModelCatalog()
    let commands = SlashCommandCatalog()
    let styles = ComposerOutputStyleCatalog()
    var files: [String] = []

    func receive(_ context: ServerWorkspaceContext) {
        models.receive(context.composer.models)
        commands.receive(context.composer.commands.map { var value = $0; value.path = nil; return value })
        styles.receive(context.composer.styles)
        files = context.files
    }
}
