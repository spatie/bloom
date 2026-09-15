#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Security
import BloomClient
@preconcurrency import AppAuth

/// The configured identity provider issues tokens. AppAuth owns OAuth state, PKCE and refresh.
/// The keychain holds credentials; connection preferences hold only the server address.
@MainActor
public final class ServerAuthentication {
    private var states: [String: OIDAuthState] = [:]
    #if os(macOS)
    private var listener: OIDRedirectHTTPHandler?
    #else
    private var flow: (any OIDExternalUserAgentSession)?
    #endif
    private var signingIn = false
    private let service: String
    private let signInSession: URLSession?

    public init(signInSession: URLSession? = nil, credentialService: String? = nil) {
        self.signInSession = signInSession
        service = credentialService ?? (Bundle.main.bundleIdentifier ?? "be.spatie.bloom.dev") + ".server-oauth"
    }

    public func token(for address: String) async throws -> String {
        let origin = try HTTPSConnection.origin(address).absoluteString
        guard let state = try state(for: origin), state.isAuthorized else { throw ConnectionFailure("Sign in to this server first.") }
        return try await CancellableCallback<String>.run { finish in
            state.performAction(freshTokens: { [weak self] token, _, error in
                MainActor.assumeIsolated {
                    guard let token, error == nil else {
                        finish(.failure(ConnectionFailure("Your server sign-in expired. Sign in again.")))
                        return
                    }
                    do {
                        try self?.save(state, origin: origin)
                        finish(.success(token))
                    } catch { finish(.failure(error)) }
                }
            }, additionalRefreshParameters: state.lastAuthorizationResponse.request.additionalParameters?["resource"].map { ["resource": $0] })
        }
    }

    public func signIn(address: String, externalUserAgent: (any OIDExternalUserAgent)? = nil) async throws {
        guard !signingIn else { throw ConnectionFailure("A server sign-in is already in progress.") }
        let userAgent: any OIDExternalUserAgent
        if let externalUserAgent { userAgent = externalUserAgent } else {
            #if os(macOS)
            guard let window = NSApp.keyWindow else { throw ConnectionFailure("Open server settings to sign in.") }
            userAgent = OIDExternalUserAgentMac(presenting: window)
            #else
            throw ConnectionFailure("Open server settings to sign in.")
            #endif
        }
        signingIn = true
        defer {
            signingIn = false
            #if os(macOS)
            listener?.cancelHTTPListener()
            listener = nil
            #else
            flow = nil
            #endif
        }
        let origin = try HTTPSConnection.origin(address)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 20
        let session = signInSession ?? URLSession(configuration: configuration)
        defer { if signInSession == nil { session.invalidateAndCancel() } }
        let (data, response) = try await session.data(from: origin.appendingPathComponent(".well-known/bloom-auth"))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 65_536,
              response.url?.scheme == origin.scheme, response.url?.host == origin.host, response.url?.port == origin.port else {
            throw ConnectionFailure("This server has not configured HTTPS sign-in yet.")
        }
        let metadata = try JSONDecoder().decode(OAuthMetadata.self, from: data)
        try metadata.validate(for: origin)
        let serviceConfiguration = OIDServiceConfiguration(authorizationEndpoint: metadata.authorizationEndpoint,
            tokenEndpoint: metadata.tokenEndpoint, issuer: metadata.issuer, registrationEndpoint: metadata.registrationEndpoint)
        #if os(macOS)
        let listener = OIDRedirectHTTPHandler(successURL: nil)
        self.listener = listener
        var listenerError: NSError?
        let redirect = listener.startHTTPListener(&listenerError)
        if let listenerError { throw listenerError }
        #else
        let redirect = URL(string: "be.spatie.bloom.ios:/oauth/callback")!
        #endif
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
                        continuation.resume(throwing: error ?? ConnectionFailure("Native client registration failed."))
                    }
                }
            }
        }
        let request = OIDAuthorizationRequest(configuration: serviceConfiguration, clientId: clientID,
            scopes: metadata.scopes, redirectURL: redirect, responseType: OIDResponseTypeCode,
            additionalParameters: metadata.tokenParameters)
        let authorization: OIDAuthorizationResponse = try await withCheckedThrowingContinuation { continuation in
            let session = OIDAuthorizationService.present(request, externalUserAgent: userAgent) { response, error in
                if let response { continuation.resume(returning: response) } else {
                    continuation.resume(throwing: error ?? ConnectionFailure("Server sign-in was cancelled."))
                }
            }
            #if os(macOS)
            listener.currentAuthorizationFlow = session
            #else
            flow = session
            #endif
        }
        guard let exchange = authorization.tokenExchangeRequest(withAdditionalParameters: metadata.tokenParameters) else {
            throw ConnectionFailure("The server did not return an authorization code.")
        }
        let tokens: OIDTokenResponse = try await withCheckedThrowingContinuation { continuation in
            OIDAuthorizationService.perform(exchange) { response, error in
                if let response { continuation.resume(returning: response) } else { continuation.resume(throwing: error ?? ConnectionFailure("Server sign-in could not be completed.")) }
            }
        }
        let state = OIDAuthState(authorizationResponse: authorization, tokenResponse: tokens)
        try save(state, origin: origin.absoluteString)
        states[origin.absoluteString] = state
    }

    public func signOut(address: String) throws {
        let origin = try HTTPSConnection.origin(address).absoluteString
        states[origin] = nil
        let status = SecItemDelete(query(origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectionFailure("Could not remove the saved server sign-in.") }
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
        guard status == errSecSuccess, let data = result as? Data else { throw ConnectionFailure("Unlock the keychain to sign in to this server.") }
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
        guard status == errSecSuccess else { throw ConnectionFailure("Could not save the server sign-in in your keychain.") }
    }
}
