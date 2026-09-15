import Foundation
import Testing
import BloomClient
@testable import BloomCore

struct RemoteCreationContractTests {
    @Test func clientCreationRequestsUseTheActualServerSchema() throws {
        var request = RemoteCreationRequest(repositoryPath: "/repo", name: "Review", agent: .codex, model: "gpt-test")
        request.mode = .browser
        request.checkout = .pullRequest(PullRequestListing(number: 42, title: "A change", headRefName: "feature", baseRefName: "main"))
        request.runSetupScript = false
        let service = RemoteWorkspaceService(client: CreationContractTransport())
        let command = try service.creationCommand(request)
        let decoded = try JSONDecoder().decode(ServerRequest.self, from: JSONEncoder().encode(command))
        #expect(decoded.operation == .create(request))
        #expect(decoded.id == command.id)
    }

    @Test func repositoryCheckoutAndContextResultsRoundTripThroughTheServer() async throws {
        let service = RemoteWorkspaceService(client: CreationContractTransport())
        let repositories = try await service.githubRepositories(query: "spatie", page: 2)
        #expect(repositories.first?.nameWithOwner == "spatie/example")
        let context = try await service.workspaceContext(projectID: RepoID("repo"))
        #expect(context.hasSetupScript && context.composer.controls.agentKind == .codex)
        let checkouts = try await service.checkoutOptions(projectID: RepoID("repo"))
        #expect(checkouts.branches.first?.inUseBy == .workspace("Already open"))
        let resolved = try await service.resolveReference("#42", projectID: RepoID("repo"))
        #expect(resolved == .failure("No such pull request"))
    }

    @Test func createdWorkspaceAndNewSessionRetainFullComposerControls() async throws {
        let transport = CreationContractTransport()
        let service = RemoteWorkspaceService(client: transport)
        let controls = ComposerControls(model: "gpt-test", effort: "high", agentKind: .codex, permissionMode: .autoReview,
                                        isFastMode: true, codexContextWindow: 1_000_000)
        let id = UUID()
        let session = try await service.newSession(workspaceID: WorkspaceID("workspace"), controls: controls, commandID: id)
        #expect(session.agentKind == "codex")
        let requests = await transport.requests
        #expect(requests.first?.id == id)
        #expect(requests.last?.operation == .setComposer(sessionID: session.id, controls: controls))
    }
}

private actor CreationContractTransport: RemoteRequesting {
    private(set) var requests: [ServerRequest] = []
    func request(_ command: RemoteCommand) async throws -> JSONValue {
        let request = try JSONDecoder().decode(ServerRequest.self, from: JSONEncoder().encode(command))
        requests.append(request)
        let result: ServerResult
        switch request.operation {
        case .creation(.githubRepositories(let query, let page)):
            #expect(query == "spatie" && page == 2)
            result = .creation(.repositories([GitHubRepositoryListing(nameWithOwner: "spatie/example", isPrivate: true)]))
        case .creation(.workspaceContext):
            result = .creation(.workspaceContext(ServerWorkspaceContext(branches: ["main"], branchPrefix: nil, hasSetupScript: true,
                composer: ServerComposerState(controls: ComposerControls(model: "gpt-test", agentKind: .codex)), files: [])))
        case .creation(.checkouts):
            result = .creation(.checkouts(WorkspaceCheckoutOptions(branches: [.init(name: "feature", isLocal: true, inUseBy: .workspace("Already open"))])))
        case .creation(.resolveReference): result = .creation(.reference(.failure("No such pull request")))
        case .workspace(let id, .newSession(let agent, let model, let effort, let permissions)):
            let workspace = Workspace(id: id, repoID: RepoID("repo"), name: "Workspace", branch: "feature", path: "/workspace", baseBranch: "main")
            let session = Session(workspaceID: id, model: model, effort: effort, agentKind: agent, permissionMode: permissions)
            result = .created(session: session, workspace: workspace, setupSucceeded: true)
        case .setComposer: result = .accepted
        default: throw ConnectionFailure("Unexpected creation contract request")
        }
        return try RemoteClient.decode(JSONEncoder().encode(ServerReply(id: request.id, result: result)), commandID: command.id)
    }
}
