import Foundation
import Synchronization
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import BloomCore

@Suite("Socket write shutdown")
struct UnixSocketShutdownTests {
    @Test func closeInterruptsAWriterWhosePeerStoppedReading() async throws {
        let fixture = try WriteFixture()
        let finished = Mutex(false)
        let writing = Task.detached {
            fixture.connection.writeLine(String(repeating: "x", count: 1_024 * 1_024))
            finished.withLock { $0 = true }
        }
        await waitUntil("peer has output buffered") { fixture.hasOutput }
        let closing = Task.detached { fixture.connection.close() }
        await waitUntil("close interrupts the blocked writer", within: .seconds(2)) { finished.withLock { $0 } }
        // Unblock the old implementation even when this regression fails, rather than hanging
        // the entire test process on its close lock.
        fixture.closePeer()
        await closing.value; await writing.value
    }

    @Test func aStalledPeerEventuallyEndsTheConnection() async throws {
        let fixture = try WriteFixture(timeout: .milliseconds(100))
        let finished = Mutex(false)
        let writing = Task.detached {
            fixture.connection.writeLine(String(repeating: "x", count: 1_024 * 1_024))
            finished.withLock { $0 = true }
        }
        await waitUntil("stalled write times out", within: .seconds(2)) { finished.withLock { $0 } }
        fixture.closePeer()
        await writing.value
        var lines = fixture.connection.lines.makeAsyncIterator()
        #expect(await lines.next() == nil)
    }
    @Test func slowAsyncWritesLeaveTheirActorsAvailableForShutdown() async throws {
        let fixtures = try (0..<8).map { _ in try WriteFixture() }
        let actors = fixtures.map { _ in AsyncWriteActor() }
        let writing = zip(actors, fixtures).map { actor, fixture in
            Task { await actor.send(on: fixture.connection) }
        }
        await waitUntil("all slow peers have buffered output") { fixtures.allSatisfy(\.hasOutput) }
        let responsive = SocketProgress()
        let pings = actors.map { actor in Task { await actor.ping(); responsive.count.withLock { $0 += 1 } } }
        await waitUntil("actors stay responsive while peers do not read", within: .seconds(2)) { responsive.count.withLock { $0 } == actors.count }
        for fixture in fixtures { fixture.connection.close(); fixture.closePeer() }
        for task in writing { await task.value }
        for task in pings { await task.value }
    }

}

private final class WriteFixture: Sendable {
    let connection: UnixSocketConnection
    private let peer: Mutex<Int32>
    init(timeout: Duration = .seconds(30)) throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SystemCalls.streamSocketType, 0, &descriptors) == 0 else { throw ServerFailure("Could not open socket fixture") }
        var size: Int32 = 4_096
        _ = setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        connection = UnixSocketConnection(descriptor: descriptors[0], writeTimeout: timeout)
        peer = Mutex(descriptors[1])
    }
    var hasOutput: Bool {
        peer.withLock { fd in
            var value = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            return poll(&value, 1, 0) > 0
        }
    }
    func closePeer() { peer.withLock { if $0 >= 0 { SystemCalls.close($0); $0 = -1 } } }
    deinit { closePeer(); connection.close() }
}

private actor AsyncWriteActor {
    func send(on connection: UnixSocketConnection) async {
        await connection.writeLineAsync(String(repeating: "x", count: 128 * 1_024))
    }
    func ping() {}
}

private final class SocketProgress: Sendable { let count = Mutex(0) }
