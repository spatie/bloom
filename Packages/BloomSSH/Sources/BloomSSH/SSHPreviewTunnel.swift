import Foundation
import BloomClient
import Crypto
import NIOCore
import NIOPosix
import NIOSSH

/// One pinned SSH connection carries a preview's HTTP and WebSocket connections. The listener
/// exists only on device loopback and its remote destination cannot be supplied by a web page.
public final class SSHPreviewTunnel: Sendable {
    public let localPort: Int
    public let localURL: URL
    private let loop: any EventLoop
    private let state: NIOLoopBound<PreviewForwardState>

    private init(port: Int, loop: any EventLoop, state: NIOLoopBound<PreviewForwardState>) {
        localPort = port
        localURL = URL(string: "http://127.0.0.1:\(port)")!
        self.loop = loop
        self.state = state
    }

    deinit {
        let state = state
        loop.execute { state.value.close() }
    }

    public static func open(
        configuration: SSHConfiguration, privateKey: Data, fingerprint: String, remotePort: Int
    ) async throws -> SSHPreviewTunnel {
        guard (1...65_535).contains(remotePort) else { throw ConnectionFailure("Use a preview port between 1 and 65535.") }
        guard !fingerprint.isEmpty else { throw ConnectionFailure("Verify this server's SSH host key before opening its preview.") }
        try Task.checkCancellation()
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let ready = loop.makePromise(of: Void.self)
        let state = try await loop.submit {
            NIOLoopBound(PreviewForwardState(loop: loop, ready: ready, remotePort: remotePort), eventLoop: loop)
        }.get()
        let deadline = loop.scheduleTask(in: .seconds(30)) {
            state.value.fail(ConnectionFailure("The SSH preview connection timed out. Check the server and preview port, then retry."))
        }
        do {
            return try await withTaskCancellationHandler {
                let bootstrap = ClientBootstrap(group: loop).connectTimeout(.seconds(15)).channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let key = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey))
                        let ssh = NIOSSHHandler(role: .client(.init(
                            userAuthDelegate: KeyAuthentication(username: configuration.username, key: key),
                            serverAuthDelegate: HostAuthentication(expected: fingerprint)
                        )), allocator: channel.allocator, inboundChildChannelInitializer: nil)
                        try channel.pipeline.syncOperations.addHandlers(ssh, PreviewConnectionEvents(state: state.value))
                        state.value.attach(parent: channel, ssh: ssh)
                    }
                }
                _ = try await bootstrap.connect(host: configuration.host, port: configuration.port).get()
                try await ready.futureResult.get()
                try Task.checkCancellation()
                let listener = try await ServerBootstrap(group: loop, childGroup: loop)
                    .childChannelOption(ChannelOptions.autoRead, value: false)
                    .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .childChannelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 32_768, high: 65_536))
                    .childChannelInitializer { local in state.value.accept(local) }
                    .bind(host: "127.0.0.1", port: 0).get()
                try await loop.submit { try state.value.attach(listener: listener) }.get()
                try Task.checkCancellation()
                guard let port = listener.localAddress?.port else { throw ConnectionFailure("Could not allocate a local preview port.") }
                deadline.cancel()
                return SSHPreviewTunnel(port: port, loop: loop, state: state)
            } onCancel: {
                loop.execute { state.value.fail(CancellationError()) }
            }
        } catch {
            deadline.cancel()
            try? await loop.submit { state.value.close() }.get()
            throw error
        }
    }

    /// Closing the lease closes existing browser connections as well as refusing new ones.
    public func close() async {
        let future = try? await loop.submit { self.state.value.close(); return self.state.value.closedFuture }.get()
        try? await future?.get()
    }
}

/// Confined to the one loop used by the SSH connection and every accepted browser socket.
private final class PreviewForwardState {
    let loop: any EventLoop
    let remotePort: Int
    private var ready: EventLoopPromise<Void>?
    private var parent: (any Channel)?
    private var listener: (any Channel)?
    private var ssh: NIOSSHHandler?
    private var locals: [ObjectIdentifier: any Channel] = [:]
    private var closed = false
    private let completion: EventLoopPromise<Void>
    var closedFuture: EventLoopFuture<Void> { completion.futureResult }

    init(loop: any EventLoop, ready: EventLoopPromise<Void>, remotePort: Int) {
        self.loop = loop; self.ready = ready; self.remotePort = remotePort
        completion = loop.makePromise(of: Void.self)
    }

    func attach(parent: any Channel, ssh: NIOSSHHandler) {
        guard !closed else { parent.close(promise: nil); return }
        self.parent = parent; self.ssh = ssh
        // Probe only the requested loopback port. A successful channel proves authentication,
        // host-key verification, forwarding permission and a listening preview before opening UI.
        let probe = loop.makePromise(of: Channel.self)
        guard let origin = try? SocketAddress(ipAddress: "127.0.0.1", port: 0) else {
            fail(ConnectionFailure("Could not prepare the local preview connection."))
            return
        }
        ssh.createChannel(probe, channelType: .directTCPIP(.init(targetHost: "127.0.0.1", targetPort: remotePort, originatorAddress: origin))) { channel, _ in
            channel.eventLoop.makeSucceededFuture(())
        }
        let bound = NIOLoopBound(self, eventLoop: loop)
        probe.futureResult.whenComplete { result in
            switch result {
            case .success(let channel):
                channel.close(promise: nil)
                let ready = bound.value.ready; bound.value.ready = nil
                ready?.succeed(())
            case .failure(let error): bound.value.fail(error)
            }
        }
    }

    func attach(listener: any Channel) throws {
        guard !closed else { listener.close(promise: nil); throw CancellationError() }
        self.listener = listener
    }

    func accept(_ local: any Channel) -> EventLoopFuture<Void> {
        guard !closed, let ssh, locals.count < 64, let origin = local.remoteAddress else {
            local.close(promise: nil)
            return loop.makeFailedFuture(ConnectionFailure("The preview connection is unavailable. Retry the preview."))
        }
        let id = ObjectIdentifier(local)
        let bound = NIOLoopBound(self, eventLoop: loop)
        let loop = loop
        locals[id] = local
        local.closeFuture.whenComplete { _ in bound.value.locals[id] = nil }
        let child = loop.makePromise(of: Channel.self)
        let deadline = loop.scheduleTask(in: .seconds(15)) { local.close(promise: nil) }
        ssh.createChannel(child, channelType: .directTCPIP(.init(targetHost: "127.0.0.1", targetPort: remotePort, originatorAddress: origin))) { remote, _ in
            remote.eventLoop.makeCompletedFuture {
                guard !bound.value.closed, bound.value.locals[id] != nil else { throw CancellationError() }
                let pair = PreviewGlue.matchedPair()
                try remote.pipeline.syncOperations.addHandlers(PreviewSSHBytes(), pair.1)
                try local.pipeline.syncOperations.addHandler(pair.0)
            }.flatMap {
                remote.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            }
        }
        return child.futureResult.flatMap { remote in
            deadline.cancel()
            guard !bound.value.closed, bound.value.locals[id] != nil else { remote.close(promise: nil); return loop.makeFailedFuture(CancellationError()) }
            return local.setOption(ChannelOptions.autoRead, value: true)
        }.flatMapError { error in
            deadline.cancel()
            local.close(promise: nil)
            return loop.makeFailedFuture(error)
        }
    }

    func fail(_ error: Error) {
        let ready = ready; self.ready = nil
        ready?.fail(error)
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        let ready = ready; self.ready = nil
        ready?.fail(CancellationError())
        let channels = Array(locals.values) + [parent, listener].compactMap { $0 }
        for channel in channels { channel.close(promise: nil) }
        EventLoopFuture.andAllComplete(channels.map(\.closeFuture), on: loop).cascade(to: completion)
        parent = nil; listener = nil; ssh = nil
    }
}

private final class PreviewConnectionEvents: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let state: PreviewForwardState
    init(state: PreviewForwardState) { self.state = state }
    func errorCaught(context: ChannelHandlerContext, error: Error) { state.fail(error) }
    func channelInactive(context: ChannelHandlerContext) {
        state.fail(ConnectionFailure("The SSH preview connection closed. Reconnect and reopen the preview."))
        context.fireChannelInactive()
    }
}

private final class PreviewSSHBytes: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel, case .byteBuffer(let bytes) = packet.data else {
            context.fireErrorCaught(ConnectionFailure("The SSH preview returned invalid channel data.")); return
        }
        context.fireChannelRead(wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}
