import Foundation
import Testing
@testable import BloomClient

struct RemoteTerminalTests {
    @Test func handshakeOnlyNamesIssuedSocketShape() throws {
        let path = "/tmp/bloom-terminal-00000000-0000-4000-8000-000000000001.sock"
        let request = try TerminalRelayHandshake(socketPath: path)
        #expect(request.terminalProtocol == 1)
        #expect(request.terminalSocket == path)
        for invalid in ["/tmp/agent.sock", "/tmp/bloom-terminal-../agent.sock", path + "/extra", "file://" + path,
                        "/var/tmp/bloom-terminal-00000000-0000-4000-8000-000000000001.sock"] {
            #expect(throws: ConnectionFailure.self) { try TerminalRelayHandshake(socketPath: invalid) }
        }
    }

    @Test func terminalFramesKeepInputAndOutputBoundsSeparate() throws {
        let full = try RemoteTerminalFrame.input(Data(repeating: 3, count: 16_384))
        #expect(full.kind == "input")
        #expect(throws: ConnectionFailure.self) { try RemoteTerminalFrame.input(Data()) }
        #expect(throws: ConnectionFailure.self) { try RemoteTerminalFrame.input(Data(repeating: 0, count: 16_385)) }
        let frame = try RemoteTerminalFrame.resize(columns: 500, rows: 300)
        #expect(frame.columns == 500)
        #expect(throws: ConnectionFailure.self) { try RemoteTerminalFrame.resize(columns: 501, rows: 24) }
        #expect(throws: ConnectionFailure.self) { try RemoteTerminalFrame.resize(columns: 80, rows: 1) }
    }
}
