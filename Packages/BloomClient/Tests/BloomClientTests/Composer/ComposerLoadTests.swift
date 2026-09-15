import Foundation
import Testing
@testable import BloomClient

@MainActor
struct ComposerLoadTests {
    @Test func concurrentReadersBothAwaitTheSameLoadedState() async throws {
        let transport = HeldComposerTransport()
        let store = RemoteComposerStore(service: .init(client: transport), sessionID: SessionID("chat"))
        let first = Task { try await store.load(); return store.state }
        let second = Task { try await store.load(); return store.state }
        try await waitFor(2, in: store)
        await transport.waitForRequest(1)
        #expect(await transport.requestCount == 1)
        try await transport.respond(1, model: "loaded")
        #expect(try await first.value?.controls.model == "loaded")
        #expect(try await second.value?.controls.model == "loaded")
        #expect(!store.isLoading)
    }

    @Test func cancellingOneReaderKeepsTheOtherRequestAlive() async throws {
        let transport = HeldComposerTransport()
        let store = RemoteComposerStore(service: .init(client: transport), sessionID: SessionID("chat"))
        let first = Task { try await store.load() }
        let second = Task { try await store.load() }
        try await waitFor(2, in: store)
        await transport.waitForRequest(1)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(store.isLoading)
        try await transport.respond(1, model: "surviving-reader")
        try await second.value
        #expect(store.state?.controls.model == "surviving-reader")
        #expect(await transport.requestCount == 1)
    }

    @Test func cancellingLastReaderAllowsANewLoadAndIgnoresTheOldGeneration() async throws {
        let transport = HeldComposerTransport()
        let store = RemoteComposerStore(service: .init(client: transport), sessionID: SessionID("chat"))
        let first = Task { try await store.load() }
        try await waitFor(1, in: store)
        await transport.waitForRequest(1)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(!store.isLoading && store.state == nil)
        let second = Task { try await store.load() }
        try await waitFor(1, in: store)
        await transport.waitForRequest(2)
        try await transport.respond(1, model: "stale")
        try await transport.respond(2, model: "fresh")
        try await second.value
        #expect(store.state?.controls.model == "fresh" && !store.isLoading)
    }

    @Test func reconnectCancelsOldReadersAndLoadsThroughTheReplacementTransport() async throws {
        let old = HeldComposerTransport()
        let replacement = HeldComposerTransport()
        let store = RemoteComposerStore(service: .init(client: old), sessionID: SessionID("chat"))
        let original = Task { try await store.load() }
        await old.waitForRequest(1)
        try store.reconnect(using: .init(client: replacement))
        await #expect(throws: CancellationError.self) { try await original.value }
        let fresh = Task { try await store.load() }
        await replacement.waitForRequest(1)
        try await old.respond(1, model: "old transport")
        try await replacement.respond(1, model: "replacement transport")
        try await fresh.value
        #expect(store.state?.controls.model == "replacement transport")
        #expect(await old.requestCount == 1)
        #expect(await replacement.requestCount == 1)
    }

    private func waitFor(_ count: Int, in store: RemoteComposerStore) async throws {
        for _ in 0..<10_000 {
            if store.loadingWaiterCount == count { return }
            await Task.yield()
        }
        throw ConnectionFailure("Composer readers did not join the load.")
    }
}

/// Deliberately ignores transport cancellation, so late replies exercise the generation guard.
private actor HeldComposerTransport: RemoteRequesting {
    private(set) var requestCount = 0
    private var replies: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var started: [(Int, CheckedContinuation<Void, Never>)] = []

    func request(_ command: RemoteCommand) async throws -> JSONValue {
        requestCount += 1
        let index = requestCount
        return try await withCheckedThrowingContinuation { continuation in
            replies[index] = continuation
            let ready = started.filter { $0.0 <= index }
            started.removeAll { $0.0 <= index }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForRequest(_ index: Int) async {
        if requestCount >= index { return }
        await withCheckedContinuation { started.append((index, $0)) }
    }

    func respond(_ index: Int, model: String) throws {
        let state = RemoteComposerState(controls: ComposerControls(model: model))
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(state))
        replies.removeValue(forKey: index)?.resume(returning: .object(["composer": .object(["_0": value])]))
    }
}
