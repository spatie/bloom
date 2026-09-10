import Foundation
import Testing
@testable import BloomClient

struct AgentAuthenticationTests {
    @Test func olderComposerMetadataCannotEnableRetryOnAnOlderServer() async throws {
        let client = AuthenticationClient(authentication: nil)
        let service = RemoteWorkspaceService(client: client)
        await #expect(throws: ConnectionRefusal.self) {
            try await service.retryAuthenticationPausedPrompt(sessionID: SessionID("chat"), deliveryID: DeliveryID("pending"), text: "Original prompt")
        }
        #expect(await client.sends.isEmpty)
    }

    @Test func explicitRetryCarriesTheOriginalDeliveryIdentity() async throws {
        let client = AuthenticationClient(authentication: [.init(agent: .codex, state: .ready)])
        let service = RemoteWorkspaceService(client: client)
        try await service.retryAuthenticationPausedPrompt(sessionID: SessionID("chat"), deliveryID: DeliveryID("pending"), text: "Original prompt")
        let sent = try #require(await client.sends.first)
        #expect(sent.operation["send"]?["retryDeliveryID"]?.stringValue == "pending")
        #expect(sent.operation["send"]?["text"]?.stringValue == "Original prompt")
    }

    @Test func missingAndUnknownAuthenticationRemainDifferent() throws {
        let legacy = RemoteComposerState(controls: ComposerControls())
        #expect(try JSONDecoder().decode(RemoteComposerState.self, from: JSONEncoder().encode(legacy)).authentication == nil)
        let unknown = AgentAuthenticationStatus(agent: .codex, state: .unknown)
        #expect(!unknown.requiresSignIn)
        let missing = AgentAuthenticationStatus(agent: .codex, state: .signInRequired)
        #expect(missing.requiresSignIn)
        #expect(try JSONDecoder().decode(AgentAuthenticationStatus.self, from: JSONEncoder().encode(missing)) == missing)
    }
}

private actor AuthenticationClient: RemoteRequesting {
    let authentication: [AgentAuthenticationStatus]?
    private(set) var sends: [RemoteCommand] = []
    init(authentication: [AgentAuthenticationStatus]?) { self.authentication = authentication }
    func request(_ command: RemoteCommand) async throws -> JSONValue {
        if command.operation["composer"] != nil {
            let state = RemoteComposerState(controls: ComposerControls(), authentication: authentication)
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(state))
            return .object(["composer": .object(["_0": value])])
        }
        sends.append(command)
        return .object(["accepted": .object([:])])
    }
}
