import Foundation
import Testing
import BloomClient
@testable import BloomCore

struct ServerPaneSplitTests {
    @Test func splitCarriesAuthenticatedChatAndRequiresAnAnchoredClient() async throws {
        let store = try makeTestStore("server-pane-anchor")
        let workspaceID = WorkspaceID("workspace")
        let identity = BridgeIdentity(sessionID: SessionID("caller"), workspaceID: workspaceID, role: .parent)
        let broker = ServerUIBroker()
        let tool = try #require(ServerUIBridgeTools.handlers(broker: broker, store: store).first { $0.tool.name == "pane_split" })
        let legacy = try await broker.handle(.attach(workspaceID: workspaceID, clientID: UUID(), actions: ["pane_split"]), registrationID: UUID())
        guard case .attached(let oldLease) = legacy else { Issue.record("Expected lease"); return }
        let call = MCPRequest(id: .integer(1), method: "pane_split", params: .object(["sessionID": .string("forged")]))
        #expect(await tool.call(call, as: identity, store: store).isError)
        _ = try await broker.handle(.detach(leaseID: oldLease.id, token: oldLease.token), registrationID: UUID())
        let attached = try await broker.handle(.attach(workspaceID: workspaceID, clientID: UUID(), actions: ["pane_split_anchored"]), registrationID: UUID())
        guard case .attached(let lease) = attached else { Issue.record("Expected lease"); return }
        let work = Task { await tool.call(call, as: identity, store: store) }
        let polled = try await broker.handle(.poll(leaseID: lease.id, token: lease.token, wait: true), registrationID: UUID())
        guard case .requests(let batch) = polled else { Issue.record("Expected request"); work.cancel(); return }
        let request = try #require(batch.requests.first)
        #expect(request.action.name == "pane_split_anchored")
        #expect(request.action.arguments["sessionID"]?.stringValue == "caller")
        #expect(request.action.arguments["target"]?.stringValue == "this_chat")
        #expect(request.action.arguments["kind"]?.stringValue == "chat")
        work.cancel()
        #expect(await work.value.isError)
        await broker.shutdown()
    }
}
