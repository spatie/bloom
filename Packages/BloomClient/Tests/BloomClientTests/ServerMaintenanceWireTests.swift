import Foundation
import Testing
@testable import BloomClient

struct ServerMaintenanceWireTests {
    @Test func unsupportedWireNeverSendsCredentialAndOtherOperationsStillWork() async throws {
        let host = MaintenanceWireHost(supported: false)
        let wire = RemoteWireSession { try await host.exchange($0) }
        let request = try ServerMaintenanceRequest(action: .inspect, credential: "test-secret").command()
        await #expect(throws: ConnectionRefusal.self) { try await wire.request(request) }
        #expect(await host.commands.count == 2)
        #expect(await host.commands.allSatisfy { $0.operation["maintenance"] == nil })
        _ = try await wire.request(.call("catalogue"))
        #expect(await host.commands.last?.operation["catalogue"] != nil)
    }

    @Test func diagnosticsPrimeCapabilityAndIntentKeepsOriginalUUID() async throws {
        let host = MaintenanceWireHost(supported: true)
        let wire = RemoteWireSession { try await host.exchange($0) }
        _ = try await wire.request(.call("diagnostics"))
        let command = try ServerMaintenanceRequest(action: .start, credential: "test-secret", planID: "p1", mode: .now).command()
        _ = try await wire.request(command)
        let commands = await host.commands
        #expect(commands.filter { $0.operation["diagnostics"] != nil }.count == 1)
        #expect(commands.last == command)
    }
}

private actor MaintenanceWireHost {
    let supported: Bool
    var commands: [RemoteCommand] = []
    init(supported: Bool) { self.supported = supported }
    func exchange(_ data: Data) throws -> Data {
        let command = try JSONDecoder().decode(RemoteCommand.self, from: data)
        commands.append(command)
        let result: JSONValue
        if command.operation["hello"] != nil {
            result = .object(["hello": .object(["name": .string("maintenance fixture")])])
        } else if command.operation["diagnostics"] != nil {
            result = .object(["diagnostics": .object(["_0": .object(supported ? ["maintenanceManagement": .bool(true)] : [:])])])
        } else { result = .object(["accepted": .object([:])]) }
        return try JSONEncoder().encode(JSONValue.object(["version": .integer(BloomWire.version), "id": .string(command.id.uuidString), "result": result]))
    }
}
