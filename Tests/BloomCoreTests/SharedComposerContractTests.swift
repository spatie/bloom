import Foundation
import Testing
import BloomClient
@testable import BloomCore

struct SharedComposerContractTests {
    @Test func mobileComposerReadsAndWritesTheActualServerTypes() async throws {
        let controls = ComposerControls(model: "gpt-test", effort: "high", agentKind: .codex,
                                        permissionMode: .autoReview, isFastMode: true, codexContextWindow: 1_000_000)
        let state = ServerComposerState(controls: controls, models: [.init(id: "gpt-test", displayName: "GPT Test")],
                                        commands: [], styles: [], availableAgents: [.codex])
        let transport = ComposerContractTransport(state: state)
        let service = RemoteWorkspaceService(client: transport)
        let sessionID = SessionID("composer-contract")
        let received = try await service.composer(sessionID: sessionID)
        #expect(received.controls == controls && received.models == state.models)
        let fork = try await service.setComposer(sessionID: sessionID, controls: received.controls)
        #expect(fork == nil)
        let operations = await transport.operations
        #expect(operations == [.composer(sessionID: sessionID), .setComposer(sessionID: sessionID, controls: controls)])
    }
}

private actor ComposerContractTransport: RemoteRequesting {
    let state: ServerComposerState
    private(set) var operations: [ServerOperation] = []
    init(state: ServerComposerState) { self.state = state }
    func request(_ command: RemoteCommand) async throws -> JSONValue {
        let request = try JSONDecoder().decode(ServerRequest.self, from: JSONEncoder().encode(command))
        operations.append(request.operation)
        let result: ServerResult = command.operation["composer"] == nil ? .accepted : .composer(state)
        let reply = ServerReply(id: request.id, result: result)
        return try RemoteClient.decode(JSONEncoder().encode(reply), commandID: command.id)
    }
}
