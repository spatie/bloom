import AppKit
import Security
@testable import BloomCore
@preconcurrency import AppAuth

// Compiled with the app's actual ServerAuthentication and ServerHTTPTransport sources by the
// HTTPS integration runner. Trust is restricted to the temporary fixture CA in this process.
final class FixtureTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    let certificate: SecCertificate
    init(certificate: SecCertificate) { self.certificate = certificate }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else { print("Fixture trust failed:", String(describing: trustError)); completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

final class FixtureBrowser: NSObject, OIDExternalUserAgent {
    let path: String
    init(path: String) { self.path = path }
    func present(_ request: any OIDExternalUserAgentRequest, session: any OIDExternalUserAgentSession) -> Bool {
        do { try request.externalUserAgentRequestURL().absoluteString.write(toFile: path, atomically: true, encoding: .utf8); return true } catch { return false }
    }
    func dismiss(animated: Bool, completion: @escaping () -> Void) { completion() }
}

@main struct AuthHarness {
    @MainActor static func main() async throws {
        let directory = CommandLine.arguments[1]
        if CommandLine.arguments.count == 4, CommandLine.arguments[2] == "seed-agent" {
            let store = try Store(path: directory + "/data/server.sqlite")
            try await store.setSetting("agent.claudeCode.executablePath", CommandLine.arguments[3])
            return
        }
        let address = "https://control.127.0.0.1.sslip.io:19444"
        let data = try Data(contentsOf: URL(fileURLWithPath: directory + "/cert.der"))
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else { throw ServerFailure("Missing fixture certificate") }
        let session = URLSession(configuration: .ephemeral, delegate: FixtureTrust(certificate: certificate), delegateQueue: nil)
        OIDURLSessionProvider.setSession(session)
        let service = "be.spatie.bloom.https-integration." + UUID().uuidString
        let authentication = ServerAuthentication(signInSession: session, credentialService: service)
        defer { try? authentication.signOut(address: address); session.invalidateAndCancel() }
        try await authentication.signIn(address: address, externalUserAgent: FixtureBrowser(path: directory + "/authorize-url.txt"))
        print("PASS: actual Mac sign-in code, AppAuth PKCE and loopback callback")
        let first = try await authentication.token(for: address)
        try first.write(toFile: directory + "/access-token.txt", atomically: true, encoding: .utf8)
        // Reading through another instance exercises the secure Keychain archive, not the cache.
        let restored = ServerAuthentication(signInSession: session, credentialService: service)
        let fromKeychain = try await restored.token(for: address)
        guard !fromKeychain.isEmpty else { throw ServerFailure("Keychain did not restore a credential") }
        print("PASS: sign-in survives a new authentication instance through Keychain")
        let transport = try ServerHTTPTransport(baseURL: URL(string: address)!, accessToken: { try await restored.token(for: address) }, session: session)
        let hello = try await transport.request(ServerRequest(.hello), timeout: .seconds(10))
        guard case .hello = hello.result else { throw ServerFailure("HTTPS hello failed") }
        print("PASS: actual Swift HTTPS transport reaches standalone Bloom runtime")
        try "ready".write(toFile: directory + "/native-ready", atomically: true, encoding: .utf8)
        // Keep the fixture credential fresh while the separate RPC/browser checks run.
        var refreshed = false
        for _ in 0..<40 {
            try await Task.sleep(for: .seconds(15))
            let fresh = try await restored.token(for: address)
            try fresh.write(toFile: directory + "/access-token.txt", atomically: true, encoding: .utf8)
            _ = try await transport.request(ServerRequest(.catalogue), timeout: .seconds(10))
            if fresh != first, !refreshed {
                print("PASS: real provider refresh and subsequent authenticated request")
                refreshed = true
            }
            if FileManager.default.fileExists(atPath: directory + "/finish-native") { break }
        }
        guard refreshed else { throw ServerFailure("Access token did not refresh") }
        try restored.signOut(address: address)
        let signedOut = ServerAuthentication(signInSession: session, credentialService: service)
        do { _ = try await signedOut.token(for: address); throw ServerFailure("Sign-out retained a credential") } catch let error as ServerFailure {
            guard error.localizedDescription.contains("Sign in to this server first") else { throw error }
        }
        print("PASS: sign-out removes the stored credential")
    }
}
