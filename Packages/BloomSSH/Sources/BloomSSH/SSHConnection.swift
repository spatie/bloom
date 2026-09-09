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
    private var channels: [UUID: any Channel] = [:]
    private var closed = false

    public init(configuration: SSHConfiguration, privateKey: Data, fingerprint: String?) {
        self.configuration = configuration; self.privateKey = privateKey; self.fingerprint = fingerprint
    }

    public func request(_ command: RemoteCommand) async throws -> JSONValue {
        let response = try await exchange(JSONEncoder().encode(command))
        return try RemoteClient.decode(response, commandID: command.id)
    }

    public func close() {
        closed = true
        for channel in channels.values { channel.close(promise: nil) }
        channels.removeAll()
    }

    public func exchange(_ body: Data, timeout: TimeAmount = .seconds(660)) async throws -> Data {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let response = loop.makePromise(of: Data.self)
        let gate = try await loop.submit { NIOLoopBound(ReplyCompletion(response), eventLoop: loop) }.get()
        let configuration = configuration, privateKey = privateKey, fingerprint = fingerprint
        let bootstrap = ClientBootstrap(group: loop).connectTimeout(.seconds(15)).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
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
        let channel: any Channel
        do { channel = try await bootstrap.connect(host: configuration.host, port: configuration.port).get() }
        catch {
            let failure = ConnectionFailure("Could not reach SSH at \(configuration.host):\(configuration.port). Check the address, port, network and server firewall.")
            try await loop.submit { gate.value.finish(.failure(failure)) }.get()
            throw failure
        }
        let id = UUID()
        guard !closed, !Task.isCancelled else { channel.close(promise: nil); throw CancellationError() }
        channels[id] = channel
        let deadline = loop.scheduleTask(in: timeout) {
            gate.value.finish(.failure(ConnectionFailure("SSH request timed out. Check the server and retry with the same command ID.")))
            channel.close(promise: nil)
        }
        defer { deadline.cancel(); channels[id] = nil; channel.close(promise: nil) }
        return try await withTaskCancellationHandler {
            try await response.futureResult.get()
        } onCancel: { channel.close(promise: nil) }
    }
}

private final class ReplyCompletion {
    private var promise: EventLoopPromise<Data>?
    init(_ promise: EventLoopPromise<Data>) { self.promise = promise }
    func finish(_ result: Result<Data, Error>) { let promise = promise; self.promise = nil; promise?.completeWith(result) }
}

private final class KeyAuthentication: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let key: NIOSSHPrivateKey
    private var offered = false
    init(username: String, key: NIOSSHPrivateKey) { self.username = username; self.key = key }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(ConnectionFailure("The server refused this device's SSH key. Add its public key to the selected account's authorised keys.")); return
        }
        offered = true
        nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key))))
    }
}

private final class HostAuthentication: NIOSSHClientServerAuthenticationDelegate {
    let expected: String?
    init(expected: String?) { self.expected = expected }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            let fingerprint = try SSHIdentity.fingerprint(publicKey: String(openSSHPublicKey: hostKey))
            guard let expected else { throw SSHHostTrustRequired(fingerprint: fingerprint) }
            guard expected == fingerprint else { throw ConnectionFailure("The server's SSH host key has changed. Connection refused. Verify the new key with your server administrator before removing its saved trust.") }
            validationCompletePromise.succeed(())
        } catch { validationCompletePromise.fail(error) }
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
    init(command: String, body: Data, completion: ReplyCompletion) { self.command = command; self.body = body; self.completion = completion }
    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count + 1)
        buffer.writeBytes(body); buffer.writeInteger(UInt8(10))
        context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
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
