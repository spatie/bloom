import Foundation

/// The selected server advertises its administrator-configured native OAuth client over HTTPS.
/// Provider endpoints must share the issuer's authority, including its port. No vendor is trusted
/// implicitly, and a provider change always starts a fresh authorisation flow.
public struct OAuthMetadata: Codable, Sendable {
    public var issuer: URL
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    public var clientID: String?
    public var scopes: [String] = ["openid", "email", "offline_access"]
    public var resource: String?

    public init(issuer: URL, authorizationEndpoint: URL, tokenEndpoint: URL,
                registrationEndpoint: URL? = nil, clientID: String? = nil,
                scopes: [String] = ["openid", "email", "offline_access"], resource: String? = nil) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.clientID = clientID
        self.scopes = scopes
        self.resource = resource
    }

    enum CodingKeys: String, CodingKey {
        case issuer, scopes, resource
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case clientID = "client_id"
    }

    public func validate(for origin: URL) throws {
        _ = try HTTPSConnection.origin(origin.absoluteString)
        for url in [issuer, authorizationEndpoint, tokenEndpoint] + (registrationEndpoint.map { [$0] } ?? []) {
            guard url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
                  let host = url.host, !host.isEmpty, host == issuer.host, url.port == issuer.port else {
                throw ConnectionFailure("The server advertised an unsafe sign-in endpoint.")
            }
        }
        guard clientID?.isEmpty == false || registrationEndpoint != nil else {
            throw ConnectionFailure("Configure a native OAuth client ID or registration endpoint on this server.")
        }
        guard !scopes.isEmpty, scopes.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }) else {
            throw ConnectionFailure("The server advertised invalid sign-in scopes.")
        }
    }

    public var tokenParameters: [String: String]? {
        resource.map { ["resource": $0] }
    }
}
