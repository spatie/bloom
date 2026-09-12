import Foundation
import Testing
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BloomCore

@Suite("ServerHTTP")
struct ServerHTTPTests {
    @Test func rejectsUnsafeServerOrigins() throws {
        for value in ["http://server.example", "https://user:secret@server.example", "https://server.example/path", "https://server.example?token=secret", "https://server.example#token"] {
            #expect(throws: ServerFailure.self) { try ServerHTTPTransport.origin(value) }
        }
        #expect(try ServerHTTPTransport.origin("https://SERVER.example/").absoluteString == "https://server.example")
    }

    @Test func endpointNeverCarriesCredentialsAndCannotLaunchLocalTerminal() throws {
        let endpoint = ServerEndpoint.https(url: "https://server.example")
        #expect(try endpoint.launch == nil)
        #expect(throws: ServerFailure.self) {
            try endpoint.terminalLaunch(ServerTerminal(executable: "/bin/sh", socket: "/tmp/test", session: "test"))
        }
    }

    @Test func validatesProviderIndependentOAuthMetadata() throws {
        let origin = try ServerHTTPTransport.origin("https://server.example")
        let valid = ServerOAuthMetadata(issuer: URL(string: "https://identity.example/realms/bloom")!,
            authorizationEndpoint: URL(string: "https://identity.example/realms/bloom/authorize")!,
            tokenEndpoint: URL(string: "https://identity.example/realms/bloom/token")!,
            registrationEndpoint: URL(string: "https://identity.example/realms/bloom/register")!)
        try valid.validate(for: origin)
        var wrong = valid
        wrong.tokenEndpoint = URL(string: "https://attacker.example/token")!
        #expect(throws: ServerFailure.self) { try wrong.validate(for: origin) }
        wrong = valid; wrong.authorizationEndpoint = URL(string: "http://server.example/authorize")!
        #expect(throws: ServerFailure.self) { try wrong.validate(for: origin) }
    }

    @Test func configuredClientDoesNotRequireRegistrationOrResourceParameters() throws {
        let data = Data(#"{"issuer":"https://login.example/realms/bloom","authorization_endpoint":"https://login.example/realms/bloom/authorize","token_endpoint":"https://login.example/realms/bloom/token","client_id":"bloom-mac","scopes":["openid","bloom:control"]}"#.utf8)
        var metadata = try JSONDecoder().decode(ServerOAuthMetadata.self, from: data)
        let origin = try ServerHTTPTransport.origin("https://server.example")
        try metadata.validate(for: origin)
        #expect(metadata.clientID == "bloom-mac")
        #expect(metadata.registrationEndpoint == nil)
        #expect(metadata.tokenParameters == nil)
        metadata.resource = "https://server.example"
        #expect(metadata.tokenParameters == ["resource": "https://server.example"])
        metadata.clientID = nil
        #expect(throws: ServerFailure.self) { try metadata.validate(for: origin) }
    }

    @Test func metadataRejectsChangedPortsCredentialsAndInvalidScopes() throws {
        let origin = try ServerHTTPTransport.origin("https://server.example")
        let valid = ServerOAuthMetadata(issuer: URL(string: "https://login.example:9443/tenant")!,
            authorizationEndpoint: URL(string: "https://login.example:9443/authorize")!,
            tokenEndpoint: URL(string: "https://login.example:9443/token")!, clientID: "bloom-mac")
        try valid.validate(for: origin)
        for endpoint in ["https://login.example:9444/token", "https://login.example/token", "http://login.example:9443/token",
                         "https://user:secret@login.example:9443/token", "https://login.example:9443/token?secret=x", "https://login.example:9443/token#fragment"] {
            var wrong = valid
            wrong.tokenEndpoint = URL(string: endpoint)!
            #expect(throws: ServerFailure.self) { try wrong.validate(for: origin) }
        }
        var wrong = valid
        wrong.scopes = ["openid email"]
        #expect(throws: ServerFailure.self) { try wrong.validate(for: origin) }
    }

    @Test func sendsTheExistingProtocolWithFreshCredentials() async throws {
        let host = "test-\(UUID().uuidString.lowercased()).example"
        let observed = Mutex<[URLRequest]>([])
        let expected = ServerRequest(.hello)
        TestHTTPProtocol.responses.withLock { $0[host] = { request in
            observed.withLock { $0.append(request) }
            return (200, try JSONEncoder().encode(ServerReply(id: expected.id, result: .hello(name: "Remote"))))
        } }
        defer { _ = TestHTTPProtocol.responses.withLock { $0.removeValue(forKey: host) } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestHTTPProtocol.self]
        let transport = try ServerHTTPTransport(baseURL: URL(string: "https://" + host)!, accessToken: { "oauth:test-only" }, session: URLSession(configuration: config))
        defer { transport.close() }
        _ = try await transport.request(expected, timeout: .seconds(5))
        let requests = observed.withLock { $0 }
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/rpc")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oauth:test-only")
        #expect(request.url?.query == nil)
    }

    @Test func refusesExpiredAccessAndUncorrelatedReplies() async throws {
        for status in [401, 403, 302, 200] {
            let host = "test-\(UUID().uuidString.lowercased()).example"
            TestHTTPProtocol.responses.withLock { $0[host] = { _ in
                (status, try JSONEncoder().encode(ServerReply(id: UUID(), result: .accepted)))
            } }
            defer { _ = TestHTTPProtocol.responses.withLock { $0.removeValue(forKey: host) } }
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TestHTTPProtocol.self]
            let transport = try ServerHTTPTransport(baseURL: URL(string: "https://" + host)!, accessToken: { "test" }, session: URLSession(configuration: config))
            defer { transport.close() }
            do {
                _ = try await transport.request(ServerRequest(.hello), timeout: .seconds(5))
                Issue.record("Rejected HTTPS response was accepted")
            } catch {
                if status == 401 || status == 403 { #expect(error is ServerRefusal) } else { #expect(error is ServerFailure) }
            }
        }
    }
}

private final class TestHTTPProtocol: URLProtocol, @unchecked Sendable {
    typealias Response = @Sendable (URLRequest) throws -> (Int, Data)
    static let responses = Mutex<[String: Response]>([:])
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let host = url.host, let reply = Self.responses.withLock({ $0[host] }) else { throw ServerFailure("Missing test response") }
            let (status, data) = try reply(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
