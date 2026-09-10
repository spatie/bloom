import Foundation
import BloomClient

/// Observes transport health without replaying commands. The draft store owns retry identities.
struct MobileRequestClient: RemoteRequesting {
    let base: any RemoteRequesting
    let failed: @Sendable (Error) async -> Void

    func request(_ command: RemoteCommand) async throws -> JSONValue {
        do {
            return try await Self.request(command, using: base)
        } catch {
            if !Task.isCancelled && !(error is CancellationError) { await failed(error) }
            throw error
        }
    }

    static func request(_ command: RemoteCommand, using client: any RemoteRequesting) async throws -> JSONValue {
        let reads: Set<String> = ["hello", "catalogue", "transcript"]
        guard let operation = command.operation.objectValue?.keys.first, reads.contains(operation) else {
            return try await client.request(command)
        }
        return try await RemoteReadDeadline.request(command, using: client)
    }
}
