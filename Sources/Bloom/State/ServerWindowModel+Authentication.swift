import Foundation

extension ServerWindowModel {
    func signInHTTPS() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        error = nil
        do {
            try await authentication.signIn(address: httpsAddress)
            usesHTTPS = true
            connectionMode = .remote
            await connect()
        } catch { self.error = error.localizedDescription }
    }

    func signOutHTTPS() async {
        await shutdown()
        do { try authentication.signOut(address: httpsAddress) } catch { self.error = error.localizedDescription }
    }
}
