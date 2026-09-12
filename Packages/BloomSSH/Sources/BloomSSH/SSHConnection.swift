import Foundation
import BloomClient
import Crypto
import NIOCore
import NIOPosix
import NIOSSH

/// Every RPC has its own exec channel and bounded lifetime. iOS never launches a local process.
/// Closing a transport stops outstanding reads; command IDs remain owned by the shared client.
public actor SSHConnection: RemoteRequesting {
    private let configuration: SSHConfiguration
    private let privateKey: Data
    private let fingerprint: String?
    private var requests: [UUID: @Sendable () -> Void] = [:]
    private var closed = false
    private lazy var wire = RemoteWireSession { [weak self] body in
        guard let self else { throw CancellationError() }
        return try await self.exchange(body)
    }

    public init(configuration: SSHConfiguration, privateKey: Data, fingerprint: String?) {
        self.configuration = configuration; self.privateKey = privateKey; self.fingerprint = fingerprint
    }

    public func request(_ command: RemoteCommand) async throws -> JSONValue {
        try await wire.request(command)
    }

    public func close() {
        closed = true
        for cancel in requests.values { cancel() }
        requests.removeAll()
    }

    public func exchange(_ body: Data, timeout: TimeAmount = .seconds(660)) async throws -> Data {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let response = loop.makePromise(of: Data.self)
        let gate = try await loop.submit { NIOLoopBound(ReplyCompletion(response), eventLoop: loop) }.get()
        let cancel: @Sendable () -> Void = { loop.execute { gate.value.finish(.failure(CancellationError())) } }
        guard !closed, !Task.isCancelled else { cancel(); throw CancellationError() }
        let id = UUID()
        requests[id] = cancel
        let deadline = loop.scheduleTask(in: timeout) {
            gate.value.finish(.failure(ConnectionFailure("SSH request timed out. Check the server and retry with the same command ID.")))
        }
        defer { deadline.cancel(); requests[id] = nil; cancel() }
        let configuration = configuration, privateKey = privateKey, fingerprint = fingerprint
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let bootstrap = ClientBootstrap(group: loop).connectTimeout(.seconds(15)).channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    guard gate.value.attach(channel) else { throw CancellationError() }
                    let key = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey))
                    let ssh = NIOSSHHandler(role: .client(.init(userAuthDelegate: KeyAuthentication(username: configuration.username, key: key), serverAuthDelegate: HostAuthentication(expected: fingerprint))), allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandlers(ssh, ConnectionErrors(completion: gate.value))
                    let child = channel.eventLoop.makePromise(of: Channel.self)
                    ssh.createChannel(child) { childChannel, type in
                        childChannel.eventLoop.makeCompletedFuture {
                            guard type == .session else { throw ConnectionFailure("The server rejected the SSH session.") }
                            try childChannel.pipeline.syncOperations.addHandler(ReplyHandler(command: configuration.command, body: body, completion: gate.value))
                        }
                    }
                    child.futureResult.whenFailure { gate.value.finish(.failure($0)) }
                }
            }
            // Await the lifecycle promise, not connect(): cancellation/deadline must also finish
            // during DNS and TCP setup. A late initializer observes the finished gate and closes.
            bootstrap.connect(host: configuration.host, port: configuration.port).whenFailure { _ in
                gate.value.finish(.failure(ConnectionFailure("Could not reach SSH at \(configuration.host):\(configuration.port). Check the address, port, network and server firewall.")))
            }
            return try await response.futureResult.get()
        } onCancel: { cancel() }
    }
}

private final class ReplyCompletion {
    private var promise: EventLoopPromise<Data>?
    private var parent: (any Channel)?
    init(_ promise: EventLoopPromise<Data>) { self.promise = promise }
    func attach(_ channel: any Channel) -> Bool {
        guard promise != nil else { channel.close(promise: nil); return false }
        parent = channel
        return true
    }
    func finish(_ result: Result<Data, Error>) {
        let promise = promise; self.promise = nil
        let parent = parent; self.parent = nil
        promise?.completeWith(result)
        parent?.close(promise: nil)
    }
}

private final class ConnectionErrors: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let completion: ReplyCompletion
    init(completion: ReplyCompletion) { self.completion = completion }
    func errorCaught(context: ChannelHandlerContext, error: Error) { completion.finish(.failure(error)); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) {
        completion.finish(.failure(ConnectionFailure("The SSH connection closed before Bloom replied. Check the server and retry with the same command ID.")))
        context.fireChannelInactive()
    }
}

private final class ReplyHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let command: String
    let body: Data
    let completion: ReplyCompletion
    private var bytes = Data()
    private var submitted = false
    init(command: String, body: Data, completion: ReplyCompletion) { self.command = command; self.body = body; self.completion = completion }
    func channelActive(context: ChannelHandlerContext) {
        let sent = context.eventLoop.makePromise(of: Void.self)
        let completion = NIOLoopBound(completion, eventLoop: context.eventLoop)
        sent.futureResult.whenFailure { completion.value.finish(.failure($0)) }
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: sent)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelFailureEvent {
            completion.finish(.failure(ConnectionFailure("The SSH server refused Bloom's exec command. Check this key's command restrictions and the server executable.")))
        } else if event is ChannelSuccessEvent, !submitted {
            submitted = true
            var buffer = context.channel.allocator.buffer(capacity: body.count + 1)
            buffer.writeBytes(body); buffer.writeInteger(UInt8(10))
            let sent = context.eventLoop.makePromise(of: Void.self)
            let completion = NIOLoopBound(completion, eventLoop: context.eventLoop)
            sent.futureResult.whenFailure { completion.value.finish(.failure($0)) }
            context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: sent)
        }
        context.fireUserInboundEventTriggered(event)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(let buffer) = message.data else { return }
        guard bytes.count + buffer.readableBytes <= 16_777_216 else {
            completion.finish(.failure(ConnectionFailure("Bloom's SSH response exceeded the size limit."))); context.close(promise: nil); return
        }
        bytes.append(contentsOf: buffer.readableBytesView)
        if let newline = bytes.firstIndex(of: 10) { completion.finish(.success(Data(bytes[..<newline]))) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { completion.finish(.failure(error)); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) {
        completion.finish(.failure(ConnectionFailure("Bloom Server did not reply. Check its executable path, data directory and running service.")))
        context.fireChannelInactive()
    }
}
