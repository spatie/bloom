import Foundation
import Testing
@testable import BloomCore

@Suite("Bridge shutdown drain", .tags(.persistence, .subprocess), .scratchDirectory)
struct BridgeDrainTests {
    @Test func shutdownWaitsForAnInFlightMCPMutationToFinishCleanup() async throws {
        let store = try makeTestStore("bridge-drain")
        let gate = BridgeMutationGate()
        let server = try BridgeServer(store: store, toolbox: BridgeToolbox(handlers: [HeldMutation(gate: gate)]))
        try server.start()
        let connection = try UnixSocketConnection.connect(to: server.socketPath)
        defer { connection.close() }
        var lines = connection.lines.makeAsyncIterator()
        let hello = BridgeHello(token: try server.ownerToken.load(), role: "owner")
        connection.writeLine(String(decoding: try JSONEncoder().encode(hello), as: UTF8.self))
        _ = try #require(await lines.next())
        connection.writeLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"held_mutation","arguments":{}}}"#)
        await gate.waitForEntry()
        let first = Task { await server.shutdown(); await gate.returned() }
        let second = Task { await server.shutdown(); await gate.returned() }
        await gate.waitForCancellation()
        #expect(await gate.returns == 0)
        #expect(try await store.setting("shutdown-fixture") == nil)
        await gate.release()
        await first.value; await second.value
        #expect(await gate.returns == 2)
        #expect(try await store.setting("shutdown-fixture") == "cleaned up")
    }
}

private struct HeldMutation: BridgeToolHandling {
    let gate: BridgeMutationGate
    let roles: Set<BridgeRole> = [.owner]
    let tool = BridgeTool(name: "held_mutation", description: "Isolated shutdown fixture", inputSchema: BridgeTool.noArguments)
    func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        await withTaskCancellationHandler {
            await gate.enter()
            try? await store.setSetting("shutdown-fixture", "cleaned up")
            return .init(text: "Finished")
        } onCancel: {
            Task { await gate.cancelled() }
        }
    }
}

private actor BridgeMutationGate {
    private var entered = false
    private var wasCancelled = false
    private var entryWait: CheckedContinuation<Void, Never>?
    private var cancellationWait: CheckedContinuation<Void, Never>?
    private var releaseWait: CheckedContinuation<Void, Never>?
    private(set) var returns = 0
    func enter() async {
        entered = true; entryWait?.resume(); entryWait = nil
        await withCheckedContinuation { releaseWait = $0 }
    }
    func waitForEntry() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWait = $0 }
    }
    func cancelled() { wasCancelled = true; cancellationWait?.resume(); cancellationWait = nil }
    func waitForCancellation() async {
        guard !wasCancelled else { return }
        await withCheckedContinuation { cancellationWait = $0 }
    }
    func release() { releaseWait?.resume(); releaseWait = nil }
    func returned() { returns += 1 }
}
