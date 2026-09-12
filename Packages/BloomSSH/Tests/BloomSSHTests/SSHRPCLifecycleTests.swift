import Foundation
import Testing
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import BloomClient
@testable import BloomSSH

struct SSHRPCLifecycleTests {
    @Test(.timeLimit(.minutes(1))) func execRejectionFailsWithoutSendingTheRequest() async throws {
        let fixture = try await RPCFixture.open(reject: true)
        do {
            let connection = fixture.connection()
            do {
                _ = try await connection.exchange(Data("{}".utf8), timeout: .seconds(2))
                Issue.record("Expected refused exec")
            } catch { #expect(error.localizedDescription.contains("refused Bloom's exec")) }
            try await fixture.closed.futureResult.get()
            #expect(try await fixture.receivedBytes() == 0)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @Test(.timeLimit(.minutes(1))) func requestWaitsForExecAcceptanceAndThenClosesItsChannel() async throws {
        let fixture = try await RPCFixture.open()
        do {
            let connection = fixture.connection()
            let body = Data(#"{"message":"one request"}"#.utf8)
            let task = Task { try await connection.exchange(body, timeout: .seconds(2)) }
            try await fixture.exec.futureResult.get()
            try await fixture.acceptExec()
            let response = try await task.value
            #expect(response == body)
            try await fixture.closed.futureResult.get()
            #expect(try await fixture.receivedBeforeAcceptance() == false)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @Test(.timeLimit(.minutes(1))) func cancellingOrClosingDuringHandshakeFinishesAndClosesPeer() async throws {
        for close in [false, true] {
            let fixture = try await RPCFixture.open()
            do {
                let connection = fixture.connection()
                let task = Task { try await connection.exchange(Data("{}".utf8), timeout: .seconds(2)) }
                try await fixture.exec.futureResult.get()
                if close { await connection.close() } else { task.cancel() }
                await #expect(throws: CancellationError.self) { try await task.value }
                try await fixture.closed.futureResult.get()
                #expect(try await fixture.receivedBytes() == 0)
                await fixture.close()
            } catch { await fixture.close(); throw error }
        }
    }

    @Test(.timeLimit(.minutes(1))) func deadlineClosesAnUnresponsiveExecChannel() async throws {
        let fixture = try await RPCFixture.open()
        do {
            let connection = fixture.connection()
            do {
                _ = try await connection.exchange(Data("{}".utf8), timeout: .milliseconds(50))
                Issue.record("Expected timeout")
            } catch { #expect(error.localizedDescription.contains("timed out")) }
            try await fixture.closed.futureResult.get()
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @Test(.timeLimit(.minutes(1))) func terminalExecRejectionIsReportedImmediately() async throws {
        let fixture = try await RPCFixture.open(reject: true)
        do {
            do {
                _ = try await SSHTerminalConnection.open(configuration: fixture.configuration, privateKey: SSHIdentity.generate(),
                    fingerprint: fixture.fingerprint, socketPath: "/tmp/bloom-terminal-00000000-0000-4000-8000-000000000001.sock")
                Issue.record("Expected rejected terminal exec")
            } catch { #expect(error.localizedDescription.contains("refused Bloom’s terminal command")) }
            try await fixture.closed.futureResult.get()
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }
}

private struct RPCFixture: Sendable {
    let configuration: SSHConfiguration
    let fingerprint: String
    let listener: any Channel
    let loop: any EventLoop
    let state: NIOLoopBound<RPCState>
    let exec: EventLoopPromise<Void>
    let closed: EventLoopPromise<Void>

    static func open(reject: Bool = false) async throws -> Self {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let rawKey = SSHIdentity.generate()
        let exec = loop.makePromise(of: Void.self), closed = loop.makePromise(of: Void.self)
        let state = try await loop.submit { NIOLoopBound(RPCState(exec: exec, closed: closed, reject: reject), eventLoop: loop) }.get()
        let listener = try await ServerBootstrap(group: loop, childGroup: loop).childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                state.value.parent = channel
                let key = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey))
                let ssh = NIOSSHHandler(role: .server(.init(hostKeys: [key], userAuthDelegate: RPCTestAuthentication())), allocator: channel.allocator) { child, _ in
                    child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(RPCResponder(state.value)) }
                }
                try channel.pipeline.syncOperations.addHandler(ssh)
                channel.closeFuture.whenComplete { _ in state.value.closed.succeed(()) }
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        let configuration = try SSHConfiguration(host: "127.0.0.1", port: try #require(listener.localAddress?.port), username: "rpc-test")
        let fingerprint = try SSHIdentity.fingerprint(publicKey: SSHIdentity.publicKey(rawKey))
        return Self(configuration: configuration, fingerprint: fingerprint, listener: listener, loop: loop, state: state, exec: exec, closed: closed)
    }
    func connection() -> SSHConnection { SSHConnection(configuration: configuration, privateKey: SSHIdentity.generate(), fingerprint: fingerprint) }
    func acceptExec() async throws { try await loop.submit { state.value.accept() }.get() }
    func receivedBytes() async throws -> Int { try await loop.submit { state.value.received }.get() }
    func receivedBeforeAcceptance() async throws -> Bool { try await loop.submit { state.value.earlyData }.get() }
    func close() async {
        try? await loop.submit { state.value.parent?.close(promise: nil) }.get()
        try? await listener.close().get()
    }
}

private final class RPCState {
    let exec: EventLoopPromise<Void>
    let closed: EventLoopPromise<Void>
    let reject: Bool
    var parent: (any Channel)?
    var context: ChannelHandlerContext?
    var accepted = false
    var earlyData = false
    var received = 0
    init(exec: EventLoopPromise<Void>, closed: EventLoopPromise<Void>, reject: Bool) { self.exec = exec; self.closed = closed; self.reject = reject }
    func accept() {
        accepted = true
        context?.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
    }
}
private final class RPCTestAuthentication: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) { responsePromise.succeed(.success) }
}
private final class RPCResponder: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let state: RPCState
    private var bytes = Data()
    init(_ state: RPCState) { self.state = state }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.ExecRequest {
            state.context = context
            if state.reject { context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
            state.exec.succeed(())
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel, case .byteBuffer(let buffer) = packet.data else { return }
        state.received += buffer.readableBytes
        state.earlyData = state.earlyData || !state.accepted
        guard state.accepted else { return }
        bytes.append(contentsOf: buffer.readableBytesView)
        if bytes.contains(10) {
            var reply = context.channel.allocator.buffer(capacity: bytes.count)
            reply.writeBytes(bytes)
            context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(reply))), promise: nil)
        }
    }
}
