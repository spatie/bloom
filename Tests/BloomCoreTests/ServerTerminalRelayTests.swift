import Foundation
import Testing
@testable import BloomCore

struct ServerTerminalRelayTests {
    @Test func refusesRegularFilesSymlinksAndUnrelatedSockets() throws {
        let path = "/tmp/bloom-terminal-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data().write(to: URL(fileURLWithPath: path))
        #expect(throws: ServerFailure.self) { try ServerTerminalRelay.validateSocket(path) }
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/tmp")
        #expect(throws: ServerFailure.self) { try ServerTerminalRelay.validateSocket(path) }
        #expect(throws: ServerFailure.self) { try ServerTerminalRelay.validateSocket("/tmp/agent.sock") }
    }

    @Test func acceptsOnlyRealOwnedTerminalSocket() throws {
        let path = "/tmp/bloom-terminal-\(UUID().uuidString).sock"
        let listener = try UnixSocketListener(path: path) { $0.close() }
        defer { listener.stop() }
        try ServerTerminalRelay.validateSocket(path)
    }
}
