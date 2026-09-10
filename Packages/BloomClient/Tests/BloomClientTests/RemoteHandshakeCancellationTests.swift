import Foundation
import Testing
@testable import BloomClient

struct RemoteHandshakeCancellationTests {
    @Test func cancelledWaiterReturnsWithoutWaitingForSharedHello() async throws {
        let host = HeldHandshake()
        let client = RemoteWireSession { try await host.exchange($0) }
        let first = Task { try await client.request(.call("create")) }
        await host.waitForHello(1)
        let otherCommand = RemoteCommand.call("create")
        let second = Task { try await client.request(otherCommand) }
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: .seconds(2))
        while await client.handshakeWaiterCount < 2, clock.now < limit { await Task.yield() }
        #expect(await client.handshakeWaiterCount == 2)
        let watchdog = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { await host.releaseAll() } }
        defer { watchdog.cancel() }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await host.pendingCount == 1)
        #expect(await client.handshakeWaiterCount == 1)
        await host.release(0, name: "shared")
        _ = try await second.value
        #expect(await host.mutationIDs == [otherCommand.id])
    }

    @Test func cancelledLastWaiterAllowsFreshHandshakeAndIgnoresLateReply() async throws {
        let host = HeldHandshake()
        let client = RemoteWireSession { try await host.exchange($0) }
        let original = Task { try await client.request(.call("create")) }
        await host.waitForHello(1)
        let watchdog = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { await host.releaseAll() } }
        defer { watchdog.cancel() }
        original.cancel()
        await #expect(throws: CancellationError.self) { try await original.value }
        #expect(await host.pendingCount == 1)
        let fresh = Task { try await client.request(.call("hello")) }
        await host.waitForHello(2)
        await host.release(0, name: "stale")
        await host.release(1, name: "fresh")
        let result = try await fresh.value
        #expect(result["hello"]?["name"]?.stringValue == "fresh")
        #expect(await host.mutationIDs.isEmpty)
    }
}

private actor HeldHandshake {
    private var waiting: [Int: (UUID, CheckedContinuation<Data, Error>)] = [:]
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []
    private var calls = 0
    private(set) var mutationIDs: [UUID] = []
    var pendingCount: Int { waiting.count }

    func exchange(_ data: Data) async throws -> Data {
        let command = try JSONDecoder().decode(RemoteCommand.self, from: data)
        guard command.operation["hello"] != nil else {
            mutationIDs.append(command.id)
            return reply(command.id, name: "mutation")
        }
        let index = calls
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            waiting[index] = (command.id, continuation)
            let ready = arrivals.filter { $0.0 <= calls }
            arrivals.removeAll { $0.0 <= calls }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForHello(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { arrivals.append((count, $0)) }
    }
    func release(_ index: Int, name: String) {
        guard let (id, continuation) = waiting.removeValue(forKey: index) else { return }
        continuation.resume(returning: reply(id, name: name))
    }
    func releaseAll() { for index in Array(waiting.keys) { release(index, name: "watchdog") } }
    private func reply(_ id: UUID, name: String) -> Data {
        do { return try JSONEncoder().encode(JSONValue.object(["id": .string(id.uuidString), "version": .integer(BloomWire.version),
            "result": .object(["hello": .object(["name": .string(name)])])]))
        } catch { Issue.record(error); return Data() }
    }
}
