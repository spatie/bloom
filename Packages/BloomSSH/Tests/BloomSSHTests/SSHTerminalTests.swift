import Foundation
import Testing
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import BloomClient
@testable import BloomSSH

struct SSHTerminalTests {
    @Test(.timeLimit(.minutes(1)))
    func streamsWithoutDroppingBytesAndHandlesInputResizeCloseAndReconnect() async throws {
        let hostKey = SSHIdentity.generate()
        let chunk = Data(("\u{1b}[32m" + String(repeating: "x", count: 9_990) + "\u{1b}[0m\n").utf8)
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { parent in
                parent.eventLoop.makeCompletedFuture {
                    let key = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: hostKey))
                    let ssh = NIOSSHHandler(role: .server(.init(hostKeys: [key], userAuthDelegate: TerminalTestAuthentication())), allocator: parent.allocator) { child, kind in
                        guard kind == .session else { return child.eventLoop.makeFailedFuture(ConnectionFailure("Only exec sessions are supported")) }
                        return child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(TerminalTestResponder(chunk: chunk)) }
                    }
                    try parent.pipeline.syncOperations.addHandler(ssh)
                }
            }.bind(host: "127.0.0.1", port: 0).get()
        defer { listener.close(promise: nil) }
        let configuration = try SSHConfiguration(host: "127.0.0.1", port: try #require(listener.localAddress?.port), username: "terminal-test")
        let privateKey = SSHIdentity.generate()
        let fingerprint = try SSHIdentity.fingerprint(publicKey: SSHIdentity.publicKey(hostKey))
        let path = "/tmp/bloom-terminal-00000000-0000-4000-8000-000000000001.sock"
        await #expect(throws: ConnectionFailure.self) {
            try await SSHTerminalConnection.open(configuration: configuration, privateKey: privateKey, fingerprint: "SHA256:wrong", socketPath: path)
        }
        let terminal = try await SSHTerminalConnection.open(configuration: configuration, privateKey: privateKey, fingerprint: fingerprint, socketPath: path)
        do {
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(2))
                let received = try await terminal.read()
                #expect(received == chunk)
            }
            let input = Data("printf test\r".utf8)
            try await terminal.send(input)
            #expect(try await terminal.read() == input)
            try await terminal.resize(columns: 120, rows: 40)
            #expect(try await terminal.read() == Data("120x40".utf8))
            let waiting = Task { try await terminal.read() }
            try await Task.sleep(for: .milliseconds(5))
            await terminal.close()
            #expect(try await waiting.value == nil)
            #expect(try await terminal.read() == nil)
            await #expect(throws: ConnectionFailure.self) { try await terminal.send(Data([3])) }
        } catch { await terminal.close(); throw error }
        let restored = try await SSHTerminalConnection.open(configuration: configuration, privateKey: privateKey, fingerprint: fingerprint, socketPath: path)
        for _ in 0..<40 { #expect(try await restored.read() == chunk) }
        try await restored.send(Data("exit-test".utf8))
        #expect(try await restored.read() == nil)
        await restored.close()
    }
}

private final class TerminalTestAuthentication: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) { responsePromise.succeed(.success) }
}

private final class TerminalTestResponder: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let chunk: Data
    private var bytes = Data()
    private var established = false
    init(chunk: Data) { self.chunk = chunk }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.ExecRequest { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = unwrapInboundIn(data)
        guard value.type == .channel, case .byteBuffer(let buffer) = value.data else { return }
        bytes.append(contentsOf: buffer.readableBytesView)
        while let newline = bytes.firstIndex(of: 10) {
            let line = Data(bytes[..<newline]); bytes.removeSubrange(...newline)
            if !established {
                guard (try? JSONDecoder().decode(TerminalRelayHandshake.self, from: line)) != nil else { context.close(promise: nil); return }
                established = true
                write(Data("{\"terminalReady\":true}".utf8), context: context)
                for _ in 0..<40 { output(chunk, context: context) }
            } else if let frame = try? JSONDecoder().decode(RemoteTerminalFrame.self, from: line) {
                if frame.data == Data("exit-test".utf8) {
                    context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
                    context.close(promise: nil)
                    return
                }
                if let data = frame.data { output(data, context: context) }
                if let columns = frame.columns, let rows = frame.rows { output(Data("\(columns)x\(rows)".utf8), context: context) }
            }
        }
    }
    private func output(_ data: Data, context: ChannelHandlerContext) {
        if let frame = try? JSONEncoder().encode(RemoteTerminalFrame(kind: "output", data: data)) { write(frame, context: context) }
    }
    private func write(_ data: Data, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: data.count + 1)
        buffer.writeBytes(data); buffer.writeInteger(UInt8(10))
        context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
    }
}
