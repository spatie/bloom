import Foundation

/// Credentials never become part of a persisted command identity.
public enum RemoteOrigin {
    public static func canonical(_ text: String) throws -> String {
        if var ssh = URLComponents(string: text), ssh.scheme?.lowercased() == "ssh" {
            guard let host = ssh.host, !host.isEmpty, let user = ssh.user, !user.isEmpty,
                  ssh.password == nil, ssh.query == nil, ssh.fragment == nil, ssh.path.hasPrefix("/") else {
                throw ConnectionFailure("Enter a valid SSH server address and data directory.")
            }
            ssh.scheme = "ssh"; ssh.host = host.lowercased()
            if ssh.port == 22 { ssh.port = nil }
            guard let identity = ssh.string else { throw ConnectionFailure("Invalid SSH server address.") }
            return identity
        }
        let url = try HTTPSConnection.origin(text)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ConnectionFailure("Enter a valid HTTPS server address.")
        }
        if components.port == 443 { components.port = nil }
        guard let origin = components.url else { throw ConnectionFailure("Enter a valid HTTPS server address.") }
        return origin.absoluteString
    }

}
