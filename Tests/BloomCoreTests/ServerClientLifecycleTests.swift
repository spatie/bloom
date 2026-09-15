import Foundation
import Testing
import Synchronization
@testable import BloomCore

struct ServerClientLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func failedTransportRetainsFinalDiagnosticsAfterOutputEnds() async throws {
        for _ in 0..<10 {
            let process = StreamingProcess(executable: "/bin/sh", arguments: ["-c", #"""
                IFS= read -r request
                awk 'BEGIN { for (i = 0; i < 4096; i++) print "SSH diagnostic"; printf "Permission denied (publickey)." }' >&2
                exit 255
                """#], mergeStderr: false)
            defer { process.kill() }
            do {
                let client = try await ServerClient.connect(process: process, timeout: .seconds(5))
                await client.disconnect()
                Issue.record("The fixture must reject the handshake")
            } catch {
                #expect(error.localizedDescription.hasSuffix("Permission denied (publickey).\n"))
                #expect(error.localizedDescription.count <= 4_096)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func failedLaunchRetainsItsReasonWithoutStderr() async throws {
        let executable = "/missing-bloom-fixture-" + UUID().uuidString
        let process = StreamingProcess(executable: executable, arguments: [], mergeStderr: false)
        do {
            let client = try await ServerClient.connect(process: process, timeout: .seconds(2))
            await client.disconnect()
            Issue.record("A missing executable must fail")
        } catch {
            #expect(error.localizedDescription.contains(executable))
            #expect(error.localizedDescription.contains("not found"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitDisconnectDoesNotWaitForStderrOrChildExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let received = directory.appendingPathComponent("received")
        let process = StreamingProcess(executable: "/bin/sh", arguments: ["-c", #"""
            trap '' TERM
            IFS= read -r request
            id=$(printf '%s' "$request" | sed -E 's/.*"id":"([^"]*)".*/\1/')
            printf '{"id":"%s","version":%s,"result":{"hello":{"name":"Fixture"}}}\n' "$id" "$1"
            IFS= read -r request
            touch "$2"
            while :; do sleep 1; done
            """#, "fixture", String(ServerRequest.protocolVersion), received.path], mergeStderr: false)
        defer { process.kill() }
        let client = try await ServerClient.connect(process: process, timeout: .seconds(2))
        let request = Task {
            try await client.request(ServerRequest(.send(sessionID: SessionID("session"), text: "Hello")), timeout: .seconds(2))
        }
        await waitUntil("the child received the pending request") { FileManager.default.fileExists(atPath: received.path) }
        await client.disconnect()
        do {
            _ = try await request.value
            Issue.record("Disconnect must fail the pending request")
        } catch {
            #expect(error.localizedDescription == "Disconnected from the server.")
        }
        #expect(process.isRunning)
        process.kill()
        _ = await process.exitStatus
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledRequestCanRetryItsIdentityAndReceiveAnImmediateReply() async throws {
        let directory = "/tmp/bloom-client-" + UUID().uuidString
        let peer = ClientLifecyclePeer()
        let listener = try UnixSocketListener(path: ServerDaemon.socketPath(directory: directory)) { peer.accept($0) }
        defer { listener.stop(); peer.close() }
        let client = try await ServerClient.connect(to: .local(directory: directory), timeout: .seconds(2))
        do {
            var incoming = peer.requests.makeAsyncIterator()
            let command = ServerRequest(.send(sessionID: SessionID("session"), text: "One prompt"))
            let cancelled = Task { try await client.request(command, timeout: .seconds(2)) }
            let first = try #require(await incoming.next())
            #expect(first.id == command.id)
            cancelled.cancel()
            await #expect(throws: ServerFailure.self) { try await cancelled.value }
            let retry = Task { try await client.request(command, timeout: .seconds(2)) }
            let second = try #require(await incoming.next())
            #expect(second == first)
            try await peer.reply(to: second.id)
            let reply = try await retry.value
            #expect(reply.id == command.id)
            guard case .accepted = reply.result else { Issue.record("Expected matching acknowledgement"); return }
            await client.disconnect()
        } catch { await client.disconnect(); throw error }
    }
}

private final class ClientLifecyclePeer: Sendable {
    let requests: AsyncStream<ServerRequest>
    private let continuation: AsyncStream<ServerRequest>.Continuation
    private let connections = Mutex<[UnixSocketConnection]>([])

    init() { (requests, continuation) = AsyncStream.makeStream(of: ServerRequest.self) }

    func accept(_ connection: UnixSocketConnection) {
        connections.withLock { $0.append(connection) }
        Task {
            for await line in connection.lines {
                guard let request = try? JSONDecoder().decode(ServerRequest.self, from: Data(line.utf8)) else { continue }
                if request.operation == .hello {
                    guard let data = try? JSONEncoder().encode(ServerReply(id: request.id, result: .hello(name: "Fixture"))) else { continue }
                    await connection.writeLineAsync(String(decoding: data, as: UTF8.self))
                } else { continuation.yield(request) }
            }
            continuation.finish()
        }
    }

    func reply(to id: UUID) async throws {
        let response = try JSONEncoder().encode(ServerReply(id: id, result: .accepted))
        let connected = connections.withLock { $0 }
        for connection in connected { await connection.writeLineAsync(String(decoding: response, as: UTF8.self)) }
    }

    func close() {
        for connection in connections.withLock({ $0 }) { connection.close() }
        continuation.finish()
    }
}
