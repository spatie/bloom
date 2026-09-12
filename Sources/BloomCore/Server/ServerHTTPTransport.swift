import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP carries the same requests as SSH. Credentials are supplied only at send time and never
/// become part of an endpoint, whose description is persisted in sidebar and editor cache keys.
public final class ServerHTTPTransport: Sendable {
    public typealias AccessToken = @Sendable () async throws -> String
    private let baseURL: URL
    private let accessToken: AccessToken
    private let session: URLSession

    public init(baseURL: URL, accessToken: @escaping AccessToken) throws {
        self.baseURL = try Self.origin(baseURL.absoluteString)
        self.accessToken = accessToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 660
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    init(baseURL: URL, accessToken: @escaping AccessToken, session: URLSession) throws {
        self.baseURL = try Self.origin(baseURL.absoluteString)
        self.accessToken = accessToken
        self.session = session
    }

    public static func origin(_ text: String) throws -> URL {
        guard var components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ServerFailure("Enter the server's HTTPS address without a path or credentials.")
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        guard let url = components.url else { throw ServerFailure("Enter a valid HTTPS server address.") }
        return url
    }

    public func request(_ value: ServerRequest, timeout: Duration) async throws -> ServerReply {
        let token = try await accessToken()
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw ServerFailure("Sign in to this server first.") }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/rpc"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(value)
        request.timeoutInterval = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ServerFailure("The server returned an invalid HTTPS response.") }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ServerRefusal("Server access expired or was revoked. Sign in again.")
        }
        guard response.statusCode == 200, data.count <= 16_777_216 else {
            throw ServerFailure("The HTTPS gateway could not complete this request (HTTP \(response.statusCode)). Refresh before retrying with the same request ID.")
        }
        guard let reply = try? JSONDecoder().decode(ServerReply.self, from: data), reply.id == value.id,
              reply.version == ServerRequest.protocolVersion else { throw ServerFailure("The server returned an incompatible Bloom reply.") }
        if case .failure(let message) = reply.result { throw ServerRefusal(message) }
        return reply
    }

    public func close() { session.invalidateAndCancel() }

    public func terminal(workspaceID: WorkspaceID, name: String) async throws -> URLSessionWebSocketTask {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/terminal"), resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        components?.queryItems = [URLQueryItem(name: "workspace_id", value: workspaceID.rawValue), URLQueryItem(name: "name", value: name)]
        guard let url = components?.url else { throw ServerFailure("Invalid terminal address.") }
        let token = try await accessToken()
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw ServerFailure("Sign in to this server first.") }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 65_536
        task.resume()
        return task
    }

    /// An authentication redirect must not carry a native bearer credential to another origin.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
