import Foundation
import BloomClient
import Crypto
import NIOCore
import NIOPosix
import NIOSSH

/// A pinned exec channel runs only the existing forced `connect` command. Its first line selects
/// a server-issued terminal socket; subsequent lines are the gateway's terminal frame format.
public final class SSHTerminalConnection: RemoteTerminalConnection, Sendable {
    private let loop: any EventLoop
    private let state: NIOLoopBound<SSHTerminalState>

    private init(loop: any EventLoop, state: NIOLoopBound<SSHTerminalState>) {
        self.loop = loop; self.state = state
    }

    deinit { let state = state; loop.execute { state.value.finish() } }

    public static func open(configuration: SSHConfiguration, privateKey: Data, fingerprint: String,
                            socketPath: String) async throws -> SSHTerminalConnection {
        let handshake = try JSONEncoder().encode(TerminalRelayHandshake(socketPath: socketPath))
        guard !fingerprint.isEmpty else { throw ConnectionFailure("Verify this server's SSH host key before opening a terminal.") }
        try Task.checkCancellation()
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let ready = loop.makePromise(of: Void.self)
        let state = try await loop.submit { NIOLoopBound(SSHTerminalState(loop: loop, ready: ready), eventLoop: loop) }.get()
        let deadline = loop.scheduleTask(in: .seconds(15)) {
            state.value.finish(error: ConnectionFailure("The SSH terminal relay did not respond. Update Bloom Server's connect executable and reopen the terminal."))
        }
        do {
            return try await withTaskCancellationHandler {
                let bootstrap = ClientBootstrap(group: loop).connectTimeout(.seconds(15))
                    .channelOption(ChannelOptions.autoRead, value: false)
                    .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                    .channelInitializer { parent in
                    parent.eventLoop.makeCompletedFuture {
                        state.value.parent = parent
                        let key = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey))
                        let ssh = NIOSSHHandler(role: .client(.init(userAuthDelegate: KeyAuthentication(username: configuration.username, key: key),
                            serverAuthDelegate: HostAuthentication(expected: fingerprint))), allocator: parent.allocator, inboundChildChannelInitializer: nil)
                        try parent.pipeline.syncOperations.addHandlers(SSHTerminalReadControl(state: state.value), ssh, SSHTerminalParentEvents(state: state.value))
                        let child = loop.makePromise(of: Channel.self)
                        ssh.createChannel(child) { channel, _ in
                            channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                                channel.eventLoop.makeCompletedFuture {
                                    try channel.pipeline.syncOperations.addHandler(SSHTerminalHandler(state: state.value, command: configuration.command, handshake: handshake))
                                }
                            }
                        }
                        child.futureResult.whenFailure { state.value.finish(error: $0) }
                    }
                }
                _ = try await bootstrap.connect(host: configuration.host, port: configuration.port).get()
                try await ready.futureResult.get()
                try Task.checkCancellation()
                deadline.cancel()
                return SSHTerminalConnection(loop: loop, state: state)
            } onCancel: { loop.execute { state.value.finish(error: CancellationError()) } }
        } catch {
            deadline.cancel()
            try? await loop.submit { state.value.finish(error: error) }.get()
            throw error
        }
    }

    public func read() async throws -> Data? {
        let loop = loop, state = state
        return try await withTaskCancellationHandler {
            try await loop.flatSubmit { state.value.read() }.get()
        } onCancel: { loop.execute { state.value.finish() } }
    }

    public func send(_ data: Data) async throws { try await write(RemoteTerminalFrame.input(data)) }
    public func resize(columns: Int, rows: Int) async throws { try await write(RemoteTerminalFrame.resize(columns: columns, rows: rows)) }

    private func write(_ frame: RemoteTerminalFrame) async throws {
        let data = try JSONEncoder().encode(frame)
        try await loop.flatSubmit { self.state.value.write(data) }.get()
    }

    public func close() async { try? await loop.submit { self.state.value.finish() }.get() }
}

/// Child autoRead is disabled. A read request advances the stream only when the renderer can
/// consume its next frame, preserving ANSI sequences and bounding buffered output.
private final class SSHTerminalState {
    let loop: any EventLoop
    var parent: (any Channel)?
    var context: ChannelHandlerContext?
    private var ready: EventLoopPromise<Void>?
    private var waiting: EventLoopPromise<Data?>?
    private var bytes = Data()
    private var outputs: [Data] = []
    private var queuedBytes = 0
    private var error: Error?
    private(set) var finished = false
    private(set) var established = false
    var exitStatus: Int?

    init(loop: any EventLoop, ready: EventLoopPromise<Void>) { self.loop = loop; self.ready = ready }

    func receive(_ data: Data) {
        guard !finished else { return }
        bytes.append(data)
        guard bytes.count <= 262_144 else { finish(error: ConnectionFailure("The terminal output frame exceeded its limit.")); return }
        do {
            while let newline = bytes.firstIndex(of: 10) {
                let line = Data(bytes[..<newline])
                bytes.removeSubrange(...newline)
                guard line.count <= 100_000 else { throw ConnectionFailure("The terminal output frame exceeded its limit.") }
                if !established {
                    let reply = try JSONDecoder().decode([String: JSONValue].self, from: line)
                    if let message = reply["terminalError"]?.stringValue { throw ConnectionFailure(message) }
                    guard reply["terminalReady"] == .bool(true) else { throw ConnectionFailure("Update Bloom Server's connect executable to support native terminals.") }
                    established = true
                    let ready = ready; self.ready = nil; ready?.succeed(())
                } else {
                    let frame = try JSONDecoder().decode(RemoteTerminalFrame.self, from: line)
                    guard frame.kind == "output", let data = frame.data, data.count <= 65_536 else { throw ConnectionFailure("The server returned an invalid terminal frame.") }
                    if let waiting { self.waiting = nil; waiting.succeed(data) } else {
                        queuedBytes += data.count
                        guard queuedBytes <= 262_144 else { throw ConnectionFailure("The terminal output buffer filled. Reconnect to restore its screen.") }
                        outputs.append(data)
                    }
                }
            }
        } catch { finish(error: error) }
    }

    func advanceRead() {
        if !finished && (!established || (waiting != nil && outputs.isEmpty)) {
            context?.read()
            parent?.read()
        }
    }

    func read() -> EventLoopFuture<Data?> {
        if let error { return loop.makeFailedFuture(error) }
        if !outputs.isEmpty {
            let output = outputs.removeFirst(); queuedBytes -= output.count
            return loop.makeSucceededFuture(output)
        }
        if finished { return loop.makeSucceededFuture(nil) }
        guard waiting == nil else { return loop.makeFailedFuture(ConnectionFailure("Only one terminal reader can attach to a connection.")) }
        let promise = loop.makePromise(of: Data?.self)
        waiting = promise
        advanceRead()
        return promise.futureResult
    }

    func write(_ data: Data) -> EventLoopFuture<Void> {
        guard !finished, established, let context else { return loop.makeFailedFuture(ConnectionFailure("Reconnect the terminal before typing.")) }
        guard context.channel.isWritable else { return loop.makeFailedFuture(ConnectionFailure("Terminal input is busy. Wait before sending more text.")) }
        var buffer = context.channel.allocator.buffer(capacity: data.count + 1)
        buffer.writeBytes(data); buffer.writeInteger(UInt8(10))
        return context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))))
    }

    func finish(error: Error? = nil) {
        guard !finished else { return }
        finished = true
        self.error = error
        let ready = ready; self.ready = nil
        ready?.fail(error ?? CancellationError())
        let waiting = waiting; self.waiting = nil
        if let error { waiting?.fail(error) } else { waiting?.succeed(nil) }
        context?.close(promise: nil)
        parent?.close(promise: nil)
        parent = nil
        context = nil
    }
}

private final class SSHTerminalHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let state: SSHTerminalState
    let command: String
    let handshake: Data

    init(state: SSHTerminalState, command: String, handshake: Data) { self.state = state; self.command = command; self.handshake = handshake }

    func handlerAdded(context: ChannelHandlerContext) { state.context = context }
    func channelActive(context: ChannelHandlerContext) {
        let promise = context.eventLoop.makePromise(of: Void.self)
        let state = NIOLoopBound(state, eventLoop: context.eventLoop)
        promise.futureResult.whenFailure { state.value.finish(error: $0) }
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: promise)
        var buffer = context.channel.allocator.buffer(capacity: handshake.count + 1)
        buffer.writeBytes(handshake); buffer.writeInteger(UInt8(10))
        context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        context.read()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = unwrapInboundIn(data)
        guard value.type == .channel, case .byteBuffer(let bytes) = value.data else { return }
        state.receive(Data(bytes.readableBytesView))
    }
    func channelReadComplete(context: ChannelHandlerContext) { state.advanceRead() }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus { state.exitStatus = status.exitStatus }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { state.finish(error: error) }
    func channelInactive(context: ChannelHandlerContext) {
        if state.established && state.exitStatus == 0 { state.finish() } else {
            state.finish(error: ConnectionFailure(state.established ? "The terminal connection closed. Reconnect to restore its screen." : "This server's SSH relay does not support terminals. Update its connect executable and retry."))
        }
    }
}

private final class SSHTerminalParentEvents: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let state: SSHTerminalState
    init(state: SSHTerminalState) { self.state = state }
    func errorCaught(context: ChannelHandlerContext, error: Error) { state.finish(error: error) }
    func channelInactive(context: ChannelHandlerContext) {
        state.finish(error: ConnectionFailure("The SSH terminal connection closed. Reconnect to continue."))
        context.fireChannelInactive()
    }
}

/// NIOSSH consumes parent read-complete events, so flow control must precede it in the pipeline.
private final class SSHTerminalReadControl: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let state: SSHTerminalState
    init(state: SSHTerminalState) { self.state = state }
    func channelActive(context: ChannelHandlerContext) { context.fireChannelActive(); context.read() }
    func channelReadComplete(context: ChannelHandlerContext) { context.fireChannelReadComplete(); state.advanceRead() }
}
