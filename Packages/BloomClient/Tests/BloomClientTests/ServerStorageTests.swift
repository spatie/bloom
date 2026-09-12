import Foundation
import Testing
@testable import BloomClient

struct ServerStorageTests {
    @Test func reportsAndPartialOutcomesRoundTripWithoutInventedByteEstimates() throws {
        let report = ServerStorageReport(checkedAt: Date(timeIntervalSinceReferenceDate: 0), totalBytes: 1_024, freeBytes: nil,
            dockerState: .ready, usage: [.init(kind: "Build Cache", totalCount: 3, activeCount: 1, sizeLabel: "1.2GB", reclaimableLabel: "200MB (estimated)")])
        let value = ServerStorageCleanupResult(outcomes: [
            .init(target: .buildCache, status: .completed, message: "Cache removed", reclaimedLabel: "200MB"),
            .init(target: .unusedImages, status: .uncertain, message: "Connection lost"),
        ], report: report, interrupted: true)
        let decoded = try JSONDecoder().decode(ServerStorageCleanupResult.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(decoded.needsAttention)
        #expect(decoded.report?.freeBytes == nil)
        #expect(ServerStorageCleanupTarget.allCases == [.buildCache, .unusedImages])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ServerStorageCleanupTarget.self, from: Data("\"volumes\"".utf8)) }
    }

    @Test func absentCapabilityRemainsUnknownInOlderDiagnostics() throws {
        let value = ServerDiagnostics(checkedAt: Date(), hostname: "server", operatingSystem: "Ubuntu", account: "bloom", checks: [])
        let decoded = try JSONDecoder().decode(ServerDiagnostics.self, from: JSONEncoder().encode(value))
        #expect(decoded.storageManagement == nil)
    }

    @Test(arguments: [false, true])
    func storageOperationsRequireExplicitCapability(cleanup: Bool) async throws {
        let host = StorageCapabilityHost(supported: false)
        let client = RemoteWireSession { try await host.exchange($0) }
        let command = cleanup ? RemoteCommand.call("cleanupStorage", ["targets": .array([.string("buildCache")])]) : .call("storage")
        await #expect(throws: ConnectionRefusal.self) { try await client.request(command) }
        #expect(await host.commands.map { $0.operation.objectValue?.keys.first ?? "" } == ["hello", "diagnostics"])
        _ = try await client.request(.call("catalogue"))
        #expect(await host.commands.last?.operation["catalogue"] != nil)
    }

    @Test func existingDiagnosticsPrimeCapabilityAndCleanupRetainsItsID() async throws {
        let host = StorageCapabilityHost(supported: true)
        let client = RemoteWireSession { try await host.exchange($0) }
        _ = try await client.request(.call("diagnostics"))
        let cleanup = RemoteCommand.call("cleanupStorage", ["targets": .array([.string("buildCache")])])
        _ = try await client.request(cleanup)
        let commands = await host.commands
        #expect(commands.filter { $0.operation["diagnostics"] != nil }.count == 1)
        #expect(commands.last == cleanup)
    }
}

private actor StorageCapabilityHost {
    let supported: Bool
    var commands: [RemoteCommand] = []
    init(supported: Bool) { self.supported = supported }
    func exchange(_ data: Data) throws -> Data {
        let command = try JSONDecoder().decode(RemoteCommand.self, from: data)
        commands.append(command)
        let result: JSONValue
        if command.operation["hello"] != nil { result = .object(["hello": .object(["name": .string("fixture")])]) } else if command.operation["diagnostics"] != nil {
            result = .object(["diagnostics": .object(["_0": .object(supported ? ["storageManagement": .bool(true)] : [:])])])
        } else { result = .object(["accepted": .object([:])]) }
        return try JSONEncoder().encode(JSONValue.object(["version": .integer(BloomWire.version), "id": .string(command.id.uuidString), "result": result]))
    }
}
