import Foundation
import Testing
@testable import BloomClient

@Suite("Connection refresh deadlines")
struct RemoteReadDeadlineTests {
    @Test("A timed out refresh cancels its transport and is never replayed")
    func timeoutCancelsTransport() async throws {
        let client = PausedReadClient()
        let command = RemoteCommand.call("catalogue")
        do {
            _ = try await RemoteReadDeadline.request(command, using: client, timeout: .milliseconds(20))
            Issue.record("Expected refresh timeout")
        } catch { #expect(error is ConnectionFailure) }
        let requests = await client.requests
        let cancelled = await client.cancelled
        #expect(requests == [command])
        #expect(cancelled)
    }

    @Test("Going into the background cancels the pending refresh immediately")
    func cancellation() async throws {
        let client = PausedReadClient()
        let command = RemoteCommand.call("transcript")
        let read = Task { try await RemoteReadDeadline.request(command, using: client) }
        await client.waitUntilStarted()
        read.cancel()
        do { _ = try await read.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
        let requests = await client.requests
        let cancelled = await client.cancelled
        #expect(requests == [command])
        #expect(cancelled)
    }
}

private actor PausedReadClient: RemoteRequesting {
    private(set) var requests: [RemoteCommand] = []
    private(set) var cancelled = false
    private var started: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }

    func request(_ command: RemoteCommand) async throws -> JSONValue {
        requests.append(command)
        started?.resume(); started = nil
        do { try await Task.sleep(for: .seconds(60)); return .object([:]) } catch {
            cancelled = Task.isCancelled
            throw error
        }
    }
}
