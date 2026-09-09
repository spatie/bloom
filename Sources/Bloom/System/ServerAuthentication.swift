import AppKit
import Security
import BloomCore
@preconcurrency import AppAuth

/// The configured identity provider issues tokens. AppAuth owns OAuth state, PKCE and refresh.
/// The keychain holds credentials; connection preferences hold only the server address.
@MainActor
final class ServerAuthentication {
    private var states: [String: OIDAuthState] = [:]
    private var listener: OIDRedirectHTTPHandler?
    private var signingIn = false
    private let service = (Bundle.main.bundleIdentifier ?? "be.spatie.bloom.dev") + ".server-oauth"

    func token(for address: String) async throws -> String {
        let origin = try ServerHTTPTransport.origin(address).absoluteString
        guard let state = try state(for: origin), state.isAuthorized else { throw ServerFailure("Sign in to this server first.") }
        return try await withCheckedThrowingContinuation { continuation in
            state.performAction(freshTokens: { [weak self] token, _, error in
                MainActor.assumeIsolated {
                    guard let token, error == nil else {
                        continuation.resume(throwing: ServerFailure("Your server sign-in expired. Sign in again."))
                        return
                    }
                    do {
                        try self?.save(state, origin: origin)
                        continuation.resume(returning: token)
                    } catch { continuation.resume(throwing: error) }
                }
            }, additionalRefreshParameters: state.lastAuthorizationResponse.request.additionalParameters?["resource"].map { ["resource": $0] })
        }
    }

    func signIn(address: String) async throws {
        guard !signingIn, let window = NSApp.keyWindow else { throw ServerFailure("Open server settings to sign in.") }
        signingIn = true
        defer { signingIn = false; listener?.cancelHTTPListener(); listener = nil }
        let origin = try ServerHTTPTransport.origin(address)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: origin.appendingPathComponent(".well-known/bloom-auth"))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 65_536,
              response.url?.scheme == origin.scheme, response.url?.host == origin.host, response.url?.port == origin.port else {
            throw ServerFailure("This server has not configured HTTPS sign-in yet.")
        }
        let metadata = try JSONDecoder().decode(ServerOAuthMetadata.self, from: data)
        try metadata.validate(for: origin)
        let serviceConfiguration = OIDServiceConfiguration(authorizationEndpoint: metadata.authorizationEndpoint,
            tokenEndpoint: metadata.tokenEndpoint, issuer: metadata.issuer, registrationEndpoint: metadata.registrationEndpoint)
        let listener = OIDRedirectHTTPHandler(successURL: nil)
        self.listener = listener
        var listenerError: NSError?
        let redirect = listener.startHTTPListener(&listenerError)
        if let listenerError { throw listenerError }
        let clientID: String
        if let configured = metadata.clientID, !configured.isEmpty {
            clientID = configured
        } else {
            let registration = OIDRegistrationRequest(configuration: serviceConfiguration, redirectURIs: [redirect],
                responseTypes: ["code"], grantTypes: ["authorization_code", "refresh_token"], subjectType: nil,
                tokenEndpointAuthMethod: "none", additionalParameters: ["client_name": "Bloom"])
            clientID = try await withCheckedThrowingContinuation { continuation in
                OIDAuthorizationService.perform(registration) { response, error in
                    if let response { continuation.resume(returning: response.clientID) } else {
                        continuation.resume(throwing: error ?? ServerFailure("Native client registration failed."))
                    }
                }
            }
        }
        let request = OIDAuthorizationRequest(configuration: serviceConfiguration, clientId: clientID,
            scopes: metadata.scopes, redirectURL: redirect, responseType: OIDResponseTypeCode,
            additionalParameters: metadata.tokenParameters)
        let authorization: OIDAuthorizationResponse = try await withCheckedThrowingContinuation { continuation in
            listener.currentAuthorizationFlow = OIDAuthorizationService.present(request,
                externalUserAgent: OIDExternalUserAgentMac(presenting: window)) { response, error in
                    if let response { continuation.resume(returning: response) } else { continuation.resume(throwing: error ?? ServerFailure("Server sign-in was cancelled.")) }
                }
        }
        guard let exchange = authorization.tokenExchangeRequest(withAdditionalParameters: metadata.tokenParameters) else {
            throw ServerFailure("The server did not return an authorization code.")
        }
        let tokens: OIDTokenResponse = try await withCheckedThrowingContinuation { continuation in
            OIDAuthorizationService.perform(exchange) { response, error in
                if let response { continuation.resume(returning: response) } else { continuation.resume(throwing: error ?? ServerFailure("Server sign-in could not be completed.")) }
            }
        }
        let state = OIDAuthState(authorizationResponse: authorization, tokenResponse: tokens)
        try save(state, origin: origin.absoluteString)
        states[origin.absoluteString] = state
    }

    func signOut(address: String) throws {
        let origin = try ServerHTTPTransport.origin(address).absoluteString
        states[origin] = nil
        let status = SecItemDelete(query(origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ServerFailure("Could not remove the saved server sign-in.") }
    }

    private func query(_ origin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: origin]
    }

    private func state(for origin: String) throws -> OIDAuthState? {
        if let state = states[origin] { return state }
        var query = query(origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ServerFailure("Unlock the keychain to sign in to this server.") }
        let state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
        states[origin] = state
        return state
    }

    private func save(_ state: OIDAuthState, origin: String) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        let query = query(origin)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ServerFailure("Could not save the server sign-in in your keychain.") }
    }
}
