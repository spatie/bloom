import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why Mailpit could not answer, in the words the Mail destination uses.
public enum MailpitFailure: Error, Equatable, Sendable {
    /// Nothing answered at the address: Mailpit is not running, or it is somewhere else.
    case unreachable
    /// Mailpit is behind `MP_UI_AUTH`, which Bloom does not send credentials for.
    case unauthorised
    /// The message is not there any more.
    case notFound
    case status(Int)
    /// Something answered, and it did not speak Mailpit's API.
    case undecodable

    public var message: String {
        switch self {
        case .unreachable: "The inbox did not answer at this address."
        case .unauthorised: "This inbox requires a password, which Bloom cannot use yet."
        case .notFound: "The message has been deleted."
        case .status(let code): "The inbox returned HTTP \(code)."
        case .undecodable: "This address does not provide a compatible inbox."
        }
    }
}

/// Mailpit's v1 API, as much of it as the Mail destination uses.
///
/// Requests are made here, in the core, and sent through an injected transport, so a test can
/// stand in for Mailpit and pin the method, the path and the body of every call. The live
/// transport is an ephemeral session with no cache and no cookies.
///
/// **`delete` with no ids does nothing, deliberately, and that is the most important line here.**
/// Mailpit's `DELETE /api/v1/messages` reads an empty list of ids as "delete every message", so an
/// empty selection passed straight through would wipe the mailbox. Clearing it is `deleteAll`,
/// which is a separate call with a separate name, so it can only ever be asked for on purpose.
public struct MailpitClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    public let base: URL
    private let transport: Transport

    public init(base: URL, transport: @escaping Transport = MailpitClient.liveTransport) {
        self.base = base
        self.transport = transport
    }

    /// How many rows a page asks for, which is Mailpit's own default.
    public static let pageSize = 50

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Short, because this is a server on this Mac or the next one along. A request that has not
        // answered in ten seconds is not going to, and the inspector should say so.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    public static let liveTransport: Transport = { request in
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - Addresses

    /// The websocket Mailpit pushes new, read and deleted messages down.
    public var eventsURL: URL {
        var components = URLComponents(url: base.appending(path: "api/events"), resolvingAgainstBaseURL: false)
        components?.scheme = base.scheme?.lowercased() == "https" ? "wss" : "ws"
        // `base` was checked to be http or https with a host, so swapping the scheme cannot fail.
        return components?.url ?? base
    }

    /// The message's HTML body as Mailpit renders it for its own preview, with inline images
    /// already pointed at its part routes so they load. This is what the reader's web view opens.
    public func htmlURL(of id: MailpitMessageID) -> URL {
        base.appending(path: "view/\(id.rawValue).html")
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let url = base.appending(path: path)
        return query.isEmpty ? url : url.appending(queryItems: query)
    }

    // MARK: - Reading

    /// Whether a Mailpit is at the address at all.
    ///
    /// A 404 here is not a deleted message, which is what `notFound` says everywhere else: it is a
    /// server with no such route, a dev server on 8025 or an old MailHog, and Settings would have
    /// told the reader "The message has been deleted" about an address. It is `undecodable`, which
    /// says what it is: something answered that is not Mailpit.
    public func info() async -> Result<MailpitInfo, MailpitFailure> {
        await decode(MailpitInfo.self, from: request("GET", url("api/v1/info")))
            .mapError { $0 == .notFound ? .undecodable : $0 }
    }

    /// One page of the list. An empty query is the whole mailbox, newest first; anything else goes
    /// to Mailpit's own search, so `from:`, `subject:` and `is:unread` work as they do in its UI.
    public func page(query: String, start: Int, limit: Int = pageSize) async -> Result<MailpitPage, MailpitFailure> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = [URLQueryItem(name: "start", value: String(start)), URLQueryItem(name: "limit", value: String(limit))]
        let path: String
        if trimmed.isEmpty {
            path = "api/v1/messages"
        } else {
            path = "api/v1/search"
            items.insert(URLQueryItem(name: "query", value: trimmed), at: 0)
        }
        return await decode(MailpitPage.self, from: request("GET", url(path, query: items)))
    }

    /// One message in full. Mailpit marks it read as it answers, which is what opening a message
    /// in its own UI does too.
    public func message(_ id: MailpitMessageID) async -> Result<MailpitMessage, MailpitFailure> {
        await decode(MailpitMessage.self, from: request("GET", url("api/v1/message/\(id.rawValue)")))
    }

    /// The message exactly as it arrived over SMTP, headers and all.
    public func source(of id: MailpitMessageID) async -> Result<String, MailpitFailure> {
        await data(request("GET", url("api/v1/message/\(id.rawValue)/raw"))).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    public func attachment(_ part: String, of id: MailpitMessageID) async -> Result<Data, MailpitFailure> {
        await data(request("GET", url("api/v1/message/\(id.rawValue)/part/\(part)")))
    }

    // MARK: - Writing

    public func markRead(_ ids: [MailpitMessageID]) async -> Result<Void, MailpitFailure> {
        guard !ids.isEmpty else { return .success(()) }
        let body = ReadBody(ids: ids.map(\.rawValue), read: true)
        return await data(request("PUT", url("api/v1/messages"), body: body)).map { _ in () }
    }

    /// Deletes exactly these messages, and nothing at all when there are none. See the head of
    /// this type for why the empty case is guarded rather than passed on.
    public func delete(_ ids: [MailpitMessageID]) async -> Result<Void, MailpitFailure> {
        guard !ids.isEmpty else { return .success(()) }
        let body = DeleteBody(ids: ids.map(\.rawValue))
        return await data(request("DELETE", url("api/v1/messages"), body: body)).map { _ in () }
    }

    /// Empties the mailbox.
    public func deleteAll() async -> Result<Void, MailpitFailure> {
        await data(request("DELETE", url("api/v1/messages"), body: DeleteBody(ids: []))).map { _ in () }
    }

    // MARK: - Sending

    private struct ReadBody: Encodable {
        var ids: [String]
        var read: Bool
        enum CodingKeys: String, CodingKey {
            case ids = "IDs"
            case read = "Read"
        }
    }

    private struct DeleteBody: Encodable {
        var ids: [String]
        enum CodingKeys: String, CodingKey { case ids = "IDs" }
    }

    private func request(_ method: String, _ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        return request
    }

    private func request(_ method: String, _ url: URL, body: some Encodable) -> URLRequest {
        var request = request(method, url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Two plain structs of strings and a flag, which cannot fail to encode.
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private func data(_ request: URLRequest) async -> Result<Data, MailpitFailure> {
        let data: Data
        let status: Int
        do {
            (data, status) = try await transport(request)
        } catch {
            // The transport's own description is about a socket, and what the reader needs is the
            // sentence `unreachable` already says.
            return .failure(.unreachable)
        }
        switch status {
        case 200..<300: return .success(data)
        case 401, 403: return .failure(.unauthorised)
        case 404: return .failure(.notFound)
        default: return .failure(.status(status))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async -> Result<T, MailpitFailure> {
        await data(request).flatMap { data in
            guard let value = try? JSONDecoder().decode(type, from: data) else { return .failure(.undecodable) }
            return .success(value)
        }
    }
}
