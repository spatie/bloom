import BloomClient
import NIOCore
import NIOSSH

final class KeyAuthentication: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let key: NIOSSHPrivateKey
    private var offered = false
    init(username: String, key: NIOSSHPrivateKey) { self.username = username; self.key = key }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(ConnectionFailure("The server refused this device's SSH key. Add its public key to the selected account's authorised keys.")); return
        }
        offered = true
        nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key))))
    }
}

final class HostAuthentication: NIOSSHClientServerAuthenticationDelegate {
    let expected: String?
    init(expected: String?) { self.expected = expected }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            let fingerprint = try SSHIdentity.fingerprint(publicKey: String(openSSHPublicKey: hostKey))
            guard let expected else { throw SSHHostTrustRequired(fingerprint: fingerprint) }
            guard expected == fingerprint else { throw ConnectionFailure("The server's SSH host key has changed. Connection refused. Verify the new key with your server administrator before removing its saved trust.") }
            validationCompletePromise.succeed(())
        } catch { validationCompletePromise.fail(error) }
    }
}
