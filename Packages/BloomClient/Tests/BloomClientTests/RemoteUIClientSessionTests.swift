import Foundation
import Testing
@testable import BloomClient

@MainActor
struct RemoteUIClientSessionTests {
    @Test func repeatedDeliveryAndLostAcknowledgementsDoNotRepeatUIActions() async throws {
        let workspace = WorkspaceID("ui-workspace")
        let host = UIClientHost(workspace: workspace)
        var performed = 0
        let client = RemoteUIClientSession(workspaceID: workspace, actions: ["pane_open"]) { _ in
            performed += 1
            return RemoteUIResult(text: "Opened browser")
        }
        client.start(using: RemoteWorkspaceService(client: host))
        await host.waitForReplies(3)
        client.stop()
        #expect(performed == 1)
        #expect(await host.results.count == 3)
        #expect(await host.results.allSatisfy { $0 == RemoteUIResult(text: "Opened browser") })
        #expect(await host.attachIDs.count == 2)
        #expect(await Set(host.attachIDs).count == 1)
    }

    @Test func unsupportedAndExpiredActionsNeverReachTheViewHandler() async throws {
        let workspace = WorkspaceID("ui-workspace")
        let host = UIClientHost(workspace: workspace, expired: true)
        var performed = 0
        let client = RemoteUIClientSession(workspaceID: workspace, actions: ["pane_open"]) { _ in
            performed += 1
            return RemoteUIResult()
        }
        client.start(using: RemoteWorkspaceService(client: host))
        await host.waitForReplies(3)
        client.stop()
        #expect(performed == 0)
        #expect(await host.results.allSatisfy(\.isError))
    }
}

private actor UIClientHost: RemoteRequesting {
    let workspace: WorkspaceID
    let expired: Bool
    let id = UUID()
    let leaseID = UUID()
    private var polls = 0
    private var waits: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var attachIDs: [UUID] = []
    private(set) var results: [RemoteUIResult] = []

    init(workspace: WorkspaceID, expired: Bool = false) { self.workspace = workspace; self.expired = expired }

    func waitForReplies(_ count: Int) async {
        if results.count >= count { return }
        await withCheckedContinuation { waits.append((count, $0)) }
    }

    func request(_ command: RemoteCommand) async throws -> JSONValue {
        let argument = try #require(command.operation["uiBridge"]?["_0"])
        let operation = try JSONDecoder().decode(RemoteUIBridgeOperation.self, from: JSONEncoder().encode(argument))
        let lease = RemoteUILease(id: leaseID, token: "test-lease", workspaceID: workspace, expiresAtMilliseconds: Int64.max)
        let result: RemoteUIBridgeResult
        switch operation {
        case .attach:
            attachIDs.append(command.id)
            if attachIDs.count == 1 { throw ConnectionFailure("Lost attachment reply") }
            result = .attached(lease)
        case .poll:
            polls += 1
            let request = RemoteUIRequest(id: id, workspaceID: workspace, action: RemoteUIAction(name: "pane_open"), expiresAtMilliseconds: expired ? 0 : Int64.max)
            result = .requests(RemoteUIBatch(lease: lease, requests: polls <= 2 ? [request] : []))
        case .claim: result = .claimed(true)
        case .respond(_, _, _, let answer):
            results.append(answer)
            let ready = waits.filter { results.count >= $0.0 }
            waits.removeAll { results.count >= $0.0 }
            ready.forEach { $0.1.resume() }
            if results.count == 1 { throw ConnectionFailure("Lost result acknowledgement") }
            result = .accepted
        case .detach: result = .accepted
        }
        return .object(["uiBridge": .object(["_0": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))])])
    }
}
