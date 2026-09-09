import Foundation
import Testing
import BloomClient
@testable import BloomCore

struct MobileProtocolContractTests {
    @Test func sharedCommandsDecodeAsRealServerOperations() throws {
        let id = SessionID("session")
        let cases: [(RemoteCommand, ServerOperation)] = [
            (.call("hello"), .hello),
            (.call("catalogue"), .catalogue),
            (.send(sessionID: id, text: "Run tests"), .send(sessionID: id, text: "Run tests")),
            (.stop(sessionID: id), .stop(sessionID: id)),
            (.call("transcript", ["sessionID": .string(id.rawValue), "afterSeq": .integer(12)]), .transcript(sessionID: id, afterSeq: 12)),
            (.call("previewAddress", ["_0": .string("http://localhost:3100")]), .previewAddress("http://localhost:3100")),
        ]
        for (command, operation) in cases {
            let request = try JSONDecoder().decode(ServerRequest.self, from: JSONEncoder().encode(command))
            #expect(request.id == command.id)
            #expect(request.version == ServerRequest.protocolVersion)
            #expect(request.operation == operation)
        }
    }

    @Test func actualServerCatalogueDecodesOnMobile() throws {
        let repo = Repo(name: "Project", path: "/server/project")
        let workspace = Workspace(repoID: repo.id, name: "Work", branch: "work", path: "/server/work", baseBranch: "main")
        let session = Session(workspaceID: workspace.id, title: "Chat")
        let command = RemoteCommand.call("catalogue")
        let reply = ServerReply(id: command.id, result: .catalogue(ServerCatalogue(repositories: [repo], workspaces: [workspace], sessions: [session])))
        let result = try RemoteClient.decode(JSONEncoder().encode(reply), commandID: command.id)
        let catalogue = try RemoteCatalogue.decode(result)
        #expect(catalogue.repositories.first?.id == repo.id)
        #expect(catalogue.workspaces.first?.id == workspace.id)
        #expect(catalogue.sessions.first?.id == session.id)
    }

    @Test func actualServerTranscriptDecodesOnMobile() throws {
        let session = Session(workspaceID: WorkspaceID("workspace"))
        let message = Message(sessionID: session.id, seq: 1, kind: .assistantText, payload: Data(#"{"text":"Hello"}"#.utf8))
        let transcript = ServerTranscript(session: session, messages: [message], pendingQuestions: [], isBusy: false, streamingText: "", permissionDecisions: [:], queuedPrompts: [], queueError: nil)
        let command = RemoteCommand.call("transcript")
        let reply = ServerReply(id: command.id, result: .transcript(transcript))
        let result = try RemoteClient.decode(JSONEncoder().encode(reply), commandID: command.id)
        let decoded = try RemoteTranscript.decode(result)
        #expect(decoded.messages.first?.text == "Hello")
        #expect(decoded.session.id == session.id)
    }

    @Test func workspaceCreationUsesActualServerDefaults() async throws {
        let controls = ComposerControls(model: "server-model", effort: "medium", agentKind: .codex, permissionMode: .plan)
        let state = ServerComposerState(controls: controls, models: [], commands: [], styles: [], availableAgents: [.codex])
        let context = ServerWorkspaceContext(branches: ["main"], branchPrefix: nil, hasSetupScript: true, composer: state, files: [])
        let encoded = try JSONEncoder().encode(ServerResult.creation(.workspaceContext(context)))
        let client = ContractClient(result: try JSONDecoder().decode(BloomClient.JSONValue.self, from: encoded))
        let repo = Repo(name: "Project", path: "/server/project")
        let project = try JSONDecoder().decode(RemoteProject.self, from: JSONEncoder().encode(repo))
        let command = try await RemoteWorkspaceService(client: client).workspaceCommand(project: project, name: "Task", prompt: "Run tests")
        let request = try JSONDecoder().decode(ServerRequest.self, from: JSONEncoder().encode(command))
        guard case .create(let creation) = request.operation else { Issue.record("Expected creation"); return }
        #expect(creation.agent == .codex)
        #expect(creation.model == "server-model")
        #expect(creation.controls == controls)
        #expect(creation.repositoryPath == repo.path)
        #expect(creation.runSetupScript == true)
        #expect(creation.mode == .chat)
    }
}

private actor ContractClient: RemoteRequesting {
    let result: BloomClient.JSONValue
    init(result: BloomClient.JSONValue) { self.result = result }
    func request(_ command: RemoteCommand) async throws -> BloomClient.JSONValue { result }
}
