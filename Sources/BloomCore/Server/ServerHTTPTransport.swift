import Foundation
import BloomClient
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Desktop and mobile share HTTPS security and connection lifetime. The host protocol adapter
/// keeps execution-only types out of the mobile dependency graph.
public final class ServerHTTPTransport: Sendable {
    public typealias AccessToken = HTTPSConnection.AccessToken
    private let connection: HTTPSConnection

    public init(baseURL: URL, accessToken: @escaping AccessToken) throws {
        connection = try HTTPSConnection(baseURL: baseURL, accessToken: accessToken)
    }

    init(baseURL: URL, accessToken: @escaping AccessToken, session: URLSession) throws {
        connection = try HTTPSConnection(baseURL: baseURL, accessToken: accessToken, session: session)
    }

    public static func origin(_ text: String) throws -> URL { try HTTPSConnection.origin(text) }

    public func request(_ value: ServerRequest, timeout: Duration) async throws -> ServerReply {
        let data = try await connection.exchange(JSONEncoder().encode(value), timeout: timeout)
        guard let reply = try? JSONDecoder().decode(ServerReply.self, from: data), reply.id == value.id,
              reply.version == ServerRequest.protocolVersion else {
            throw ServerFailure("The server returned an incompatible Bloom reply.")
        }
        if case .failure(let message) = reply.result { throw ServerRefusal(message) }
        return reply
    }

    public func close() { connection.close() }

    public func terminal(workspaceID: WorkspaceID, name: String) async throws -> URLSessionWebSocketTask {
        try await connection.terminal(workspaceID: workspaceID.rawValue, name: name)
    }
}
