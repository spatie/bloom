import Foundation
import Testing
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import BloomClient
@testable import BloomSSH

struct PreviewForwardingTests {
    @Test(.timeLimit(.minutes(1)))
    func forwardsMultipleConnectionsAndLargeResponsesThenCloses() async throws {
        let rawHostKey = SSHIdentity.generate()
        let body = "<html><title>Preview integration</title>" + String(repeating: "x", count: 180_000) + "</html>"
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let hostKey = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: rawHostKey))
                    let handler = NIOSSHHandler(role: .server(.init(hostKeys: [hostKey], userAuthDelegate: PreviewTestAuthentication())), allocator: channel.allocator) { child, kind in
                        guard case .directTCPIP(let target) = kind, target.targetHost == "127.0.0.1", target.targetPort == 3190 else {
                            return child.eventLoop.makeFailedFuture(ConnectionFailure("Unexpected forwarding destination"))
                        }
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(PreviewHTTPResponder(body: body))
                        }
                    }
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }.bind(host: "127.0.0.1", port: 0).get()
        do {
            let configuration = try SSHConfiguration(host: "127.0.0.1", port: try #require(listener.localAddress?.port), username: "preview-test")
            let key = SSHIdentity.generate()
            let fingerprint = try SSHIdentity.fingerprint(publicKey: SSHIdentity.publicKey(rawHostKey))
            await #expect(throws: ConnectionFailure.self) {
                try await SSHPreviewTunnel.open(configuration: configuration, privateKey: key, fingerprint: "SHA256:wrong", remotePort: 3190)
            }
            let tunnel = try await SSHPreviewTunnel.open(configuration: configuration, privateKey: key, fingerprint: fingerprint, remotePort: 3190)
            do {
                #expect(tunnel.localURL.host == "127.0.0.1")
                let url = tunnel.localURL
                let received = try await withThrowingTaskGroup(of: Data.self) { group in
                    for _ in 0..<3 {
                        group.addTask {
                            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
                            let (data, response) = try await URLSession.shared.data(for: request)
                            #expect((response as? HTTPURLResponse)?.statusCode == 200)
                            return data
                        }
                    }
                    var values: [Data] = []
                    for try await data in group { values.append(data) }
                    return values
                }
                #expect(received.count == 3)
                #expect(received.allSatisfy { $0 == Data(body.utf8) })
                await tunnel.close()
                await #expect(throws: (any Error).self) {
                    try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2))
                }
            } catch { await tunnel.close(); throw error }
            try await listener.close().get()
        } catch { try? await listener.close().get(); throw error }
    }
}

private final class PreviewTestAuthentication: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        responsePromise.succeed(.success)
    }
}

private final class PreviewHTTPResponder: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let body: String
    private var replied = false
    init(body: String) { self.body = body }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !replied else { return }
        replied = true
        var response = context.channel.allocator.buffer(capacity: body.utf8.count + 128)
        response.writeString("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body)
        let written = context.eventLoop.makePromise(of: Void.self)
        let channel = context.channel
        written.futureResult.whenComplete { _ in channel.close(promise: nil) }
        context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(response))), promise: written)
    }
}
