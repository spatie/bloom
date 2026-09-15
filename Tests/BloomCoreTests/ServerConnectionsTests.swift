import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite("RPC connection ownership", .scratchDirectory)
struct ServerConnectionsTests {
    @Test func overloadClosesOnlyThatClientAndDrainsEveryAcceptedRequest() async throws {
        let gate = RequestDrainGate()
        let owner = ServerConnections(requestLimit: 2) { request in
            await withTaskCancellationHandler {
                await gate.hold()
                return ServerReply(id: request.id, result: .accepted)
            } onCancel: { Task { await gate.cancelled() } }
        }
        let path = "/tmp/bloom-rpc-" + UUID().uuidString + ".sock"
        let listener = try UnixSocketListener(path: path) { owner.accept($0) }
        defer { listener.stop(); owner.stop() }
        let client = try UnixSocketConnection.connect(to: path)
        defer { client.close() }
        let request = ServerRequest(.hello)
        let line = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        client.writeLine(line); client.writeLine(line)
        await waitUntil("two requests admitted, including duplicate wire IDs") { await gate.started == 2 }
        client.writeLine(line)
        await waitUntil("overload cancels both accepted response waiters") { await gate.cancellations == 2 }
        #expect(await gate.started == 2)
        var replies = client.lines.makeAsyncIterator()
        #expect(await replies.next() == nil)
        owner.stop()
        let drained = Mutex(false)
        let finishing = Task { await owner.drain(); drained.withLock { $0 = true } }
        #expect(drained.withLock { $0 } == false)
        await gate.release()
        await finishing.value
        #expect(drained.withLock { $0 })
    }
}

private actor RequestDrainGate {
    private(set) var started = 0
    private(set) var cancellations = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func hold() async { started += 1; await withCheckedContinuation { waiting.append($0) } }
    func cancelled() { cancellations += 1 }
    func release() {
        let held = waiting; waiting.removeAll()
        for continuation in held { continuation.resume() }
    }
}
