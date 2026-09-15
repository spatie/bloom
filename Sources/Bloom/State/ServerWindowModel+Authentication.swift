import Foundation
import BloomCore

extension ServerWindowModel {
    /// Authentication belongs to the candidate, while the current server keeps its identity.
    /// The optional authenticator lets the isolated UI probe exercise cancellation without OAuth.
    func connect(to candidate: ServerConnectionProfile,
                 authenticate: (@MainActor (String) async throws -> Void)? = nil) async -> Bool {
        guard !isSigningIn, !isConnecting, !isPerformingCommand else { return false }
        let previous = connectionProfile
        let generation = connectionGeneration
        error = nil
        do {
            if candidate.usesHTTPS {
                let address = try ServerHTTPTransport.origin(candidate.httpsAddress).absoluteString
                isSigningIn = true
                defer { isSigningIn = false }
                if let authenticate { try await authenticate(address) } else { try await authentication.signIn(address: address) }
                try Task.checkCancellation()
                guard connectionGeneration == generation, connectionProfile == previous else {
                    throw ServerFailure("The active server changed during sign-in. Select the server again to connect.")
                }
            }
            try Task.checkCancellation()
            useConnectionProfile(candidate)
            await connect()
            try Task.checkCancellation()
            guard isConnected, let endpoint else { return false }
            return PaneStateNamespace.connectionID(endpoint) == candidate.id
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func signOutHTTPS() async {
        guard usesHTTPS, !isSigningIn, !isConnecting else { return }
        await shutdown()
        do { try authentication.signOut(address: httpsAddress) } catch { self.error = error.localizedDescription }
    }
}
