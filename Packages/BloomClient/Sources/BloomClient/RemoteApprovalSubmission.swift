import Foundation

/// A retry can use a fresh transport, but never a different decision or execution origin.
public struct RemoteApprovalSubmission: Sendable {
    public let command: RemoteCommand
    private let origin: String

    public init(command: RemoteCommand, origin: String) throws {
        self.command = command
        self.origin = try RemoteOrigin.canonical(origin)
    }

    public func submit(using client: any RemoteRequesting, origin: String) async throws {
        guard try RemoteOrigin.canonical(origin) == self.origin else {
            throw ConnectionFailure("Reconnect to the server that requested this decision. No answer was sent.")
        }
        let result = try await client.request(command)
        guard result["accepted"]?.objectValue != nil else {
            throw ConnectionFailure("The server did not acknowledge this decision. Retry sends the same decision.")
        }
    }
}
