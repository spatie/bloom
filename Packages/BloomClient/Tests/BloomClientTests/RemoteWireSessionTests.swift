import Foundation
import Testing
@testable import BloomClient

struct RemoteWireSessionTests {
    @Test(arguments: [12, 13, 14])
    func negotiatesKnownVersionsBeforeSendingOnce(version: Int) async throws {
        let host = WireHost(version: version)
        let client = RemoteWireSession { try await host.exchange($0) }
        let command = RemoteCommand.send(sessionID: SessionID(rawValue: UUID().uuidString), text: "Hello")
        _ = try await client.request(command)
        let frames = await host.frames
        #expect(frames.filter { $0.operation["hello"] != nil }.map(\.version) == (version == BloomWire.version ? [BloomWire.version] : [BloomWire.version, version]))
        let sends = frames.filter { $0.operation["send"] != nil }
        #expect(sends.count == 1)
        #expect(sends.first?.id == command.id)
        #expect(sends.first?.version == version)
    }

    @Test(arguments: [11, 15])
    func refusesUnknownVersionsWithoutSendingMutation(version: Int) async {
        let host = WireHost(version: version)
        let client = RemoteWireSession { try await host.exchange($0) }
        await #expect(throws: ConnectionRefusal.self) { try await client.request(.call("create")) }
        #expect(await host.frames.count == 1)
    }

    @Test func unrelatedReplyCannotChooseLegacyProtocol() async {
        let host = WireHost(version: 12, mismatchedID: true)
        let client = RemoteWireSession { try await host.exchange($0) }
        await #expect(throws: ConnectionFailure.self) { try await client.request(.call("hello")) }
        #expect(await host.frames.count == 1)
    }

    @Test func onlyExplicitIncompatibilityAllowsLegacyHandshake() async {
        let host = WireHost(version: 12, refusesNegotiation: true)
        let client = RemoteWireSession { try await host.exchange($0) }
        await #expect(throws: ConnectionRefusal.self) { try await client.request(.call("hello")) }
        #expect(await host.frames.count == 1)
    }

    @Test func diagnosticsAreNotSentToLegacyServers() async throws {
        let host = WireHost(version: 12)
        let client = RemoteWireSession { try await host.exchange($0) }
        _ = try await client.request(.call("hello"))
        await #expect(throws: ConnectionRefusal.self) { try await client.request(.call("diagnostics")) }
        #expect(await host.frames.allSatisfy { $0.operation["hello"] != nil })
    }

    @Test func storageIsNotSentToServersWithoutDiagnostics() async {
        let host = WireHost(version: 12)
        let client = RemoteWireSession { try await host.exchange($0) }
        await #expect(throws: ConnectionRefusal.self) { try await client.request(.call("cleanupStorage", ["targets": .array([.string("buildCache")])])) }
        #expect(await host.frames.allSatisfy { $0.operation["hello"] != nil })
    }

    @Test(arguments: [12, 13])
    func uiRequestsAreNotSentToOlderServers(version: Int) async throws {
        let host = WireHost(version: version)
        let client = RemoteWireSession { try await host.exchange($0) }
        await #expect(throws: ConnectionRefusal.self) { try await client.request(.call("uiBridge")) }
        #expect(await host.frames.allSatisfy { $0.operation["hello"] != nil })
    }

    @Test func failedMutationsAreNeverAutomaticallyRetried() async {
        let host = WireHost(version: 12, failsMutation: true)
        let client = RemoteWireSession { try await host.exchange($0) }
        let command = RemoteCommand.call("create")
        await #expect(throws: ConnectionRefusal.self) { try await client.request(command) }
        let mutations = await host.frames.filter { $0.operation["create"] != nil }
        #expect(mutations.count == 1)
        #expect(mutations.first?.id == command.id)
    }

    @MainActor
    @Test func cancelledRequestDoesNotSend() async {
        let host = WireHost(version: 13)
        let client = RemoteWireSession { try await host.exchange($0) }
        let task = Task { try await client.request(.call("create")) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await host.frames.isEmpty)
    }
}

private actor WireHost {
    let version: Int
    let mismatchedID: Bool
    let refusesNegotiation: Bool
    let failsMutation: Bool
    private(set) var frames: [RemoteCommand] = []

    init(version: Int, mismatchedID: Bool = false, refusesNegotiation: Bool = false, failsMutation: Bool = false) {
        self.version = version
        self.mismatchedID = mismatchedID
        self.refusesNegotiation = refusesNegotiation
        self.failsMutation = failsMutation
    }

    func exchange(_ data: Data) throws -> Data {
        let frame = try JSONDecoder().decode(RemoteCommand.self, from: data)
        frames.append(frame)
        let result: JSONValue
        if frame.version != version {
            let reason = refusesNegotiation ? "Access denied" : "Incompatible Bloom server protocol. Update the client and server."
            result = .object(["failure": .object(["_0": .string(reason)])])
        } else if frame.operation["hello"] != nil {
            result = .object(["hello": .object(["name": .string("test-host")])])
        } else if failsMutation {
            result = .object(["failure": .object(["_0": .string("Outcome unknown")])])
        } else { result = .object(["ok": .object([:])]) }
        return try JSONEncoder().encode(JSONValue.object([
            "version": .integer(version), "id": .string((mismatchedID ? UUID() : frame.id).uuidString), "result": result,
        ]))
    }
}
